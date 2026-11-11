/*
 * onwincompat — onwin's per-process compatibility module (loaded by the CW Wine tree as cxcompatdb.so).
 *
 * The CrossOver Wine tree (CW Hack 24067) dlopen()s "<ntdll_dir>/cxcompatdb.so" at the end of
 * start_main_thread() (dlls/ntdll/unix/loader.c), and ntdll.so exports prepend_dll_path() so
 * that the module can put extra directories in front of the builtin DLL search path. That is
 * how a graphics backend (D3DMetal / DXMT / DXVK) replaces Wine's own d3d11/dxgi/d3d12/... for
 * one process.
 *
 * At that point init_startup_info() has run: the PEB, its RTL_USER_PROCESS_PARAMETERS (with
 * ImagePathName = the DOS path of the exe of *this* process, for the first process as well as
 * for children started with CreateProcess) and, for 32-bit programs, the WoW64 copy of the
 * parameters exist. No DLL of the program has been loaded yet, the PE side of ntdll has not
 * copied the environment block yet (init_user_process_params does that later).
 *
 * Input (environment, written by the onwin launcher — OnwinCore/Graphics.swift, CompatRules.swift):
 *
 *     ONWIN_BACKEND_DEFAULT=dxmt             the space's backend, already resolved ("auto" → ...)
 *     ONWIN_DLL_PATHS="dirA:dirB:..."        DLL directories of the default backend, highest first
 *     ONWIN_BACKEND_DIR_d3dmetal=<dir>       DLL directory of every available backend, used when a
 *     ONWIN_BACKEND_DIR_dxmt=<dir>           rule picks one that is not the default
 *     ONWIN_BACKEND_DIR_dxvk=<dir>
 *     ONWIN_COMPAT_RULES=<file>              rules, see below
 *     ONWIN_COMPAT_DEBUG=1                   log decisions to stderr
 *
 * Rules file: UTF-8, one rule per line, '#' starts a comment line. A rule is a list of fields
 * separated by ';' ("\;" is a literal ';'):
 *
 *     exe=<pattern>[|<pattern>...]; backend=<d3dmetal, dxmt, dxvk, wined3d or auto>; env:KEY=VALUE; ...
 *
 * Patterns are separated by '|' (it cannot occur in Windows file names; ',' and ';' can).
 * Patterns are case-insensitive globs ('*', '?'). A pattern with '\' or ':' is matched against
 * the whole Windows path of the exe (e.g. "c:\games\foo\foo.exe", "*\steam\steam.exe"), any other
 * against the file name only ("steamwebhelper.exe", "battle.net*.exe"). Unknown fields are ignored
 * (the launcher writes "from=..." for diagnostics).
 *
 * The file is ordered by priority (the launcher writes the space's per-program rules first, then
 * the built-in database). The first matching rule with a backend other than "auto" decides the
 * backend; env: values are taken from every matching rule, earlier rules win. Without a matching
 * rule the process gets ONWIN_BACKEND_DEFAULT with ONWIN_DLL_PATHS (old behaviour; when
 * ONWIN_BACKEND_DEFAULT is absent ONWIN_DLL_PATHS alone is applied, as by older launchers).
 *
 * Output, for this process only:
 *   - prepend_dll_path() for the chosen backend's directories;
 *   - CX_ACTIVE_GRAPHICS_BACKEND=<chosen> ("wined3d" when none), read by the CW patches in
 *     win32u (d3dkmt.c: HwSch caps for D3DMetal, vulkan.c: CX_LIBVULKAN only with wined3d);
 *   - the rule's env: variables.
 * Variables are set in the Unix environment (read by unix libraries: D3DMetal, MoltenVK, Metal)
 * and in the process's Windows environment block (read by PE DLLs such as DXVK and DXMT through
 * GetEnvironmentVariable, and visible to "cmd /c set"). Child processes inherit both, so before
 * applying rules each process restores the variables a parent's rule changed: the original
 * value of every rule variable KEY is kept in ONWIN_COMPAT_ORIG_KEY ("+value" or "-" = unset).
 * Variables read by Wine or Rosetta before this point (WINE*, ROSETTA_*) only reach children.
 *
 * Nothing allocated here is freed by ntdll: strings handed to prepend_dll_path() and the new
 * environment blocks (NtAllocateVirtualMemory) are intentionally leaked.
 */

#include <crt_externs.h>
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

typedef void (*prepend_dll_path_fn)(const char *path);
typedef void *(*nt_current_teb_fn)(void);
typedef int32_t (*nt_allocate_virtual_memory_fn)(void *process, void **addr, uintptr_t zero_bits,
                                                 size_t *size, uint32_t type, uint32_t protect);

#define MAX_RULE_ENV   64
#define MAX_PATHS      32
#define ORIG_PREFIX    "ONWIN_COMPAT_ORIG_"

/* Windows structure offsets (x86_64 host side; checked against wine/include/winternl.h). */
#define TEB64_PEB            0x60
#define TEB64_WOWTEBOFFSET   0x180c
#define PEB64_PARAMS         0x20
#define PARAMS64_IMAGEPATH   0x60
#define PARAMS64_CMDLINE     0x70
#define PARAMS64_ENV         0x80
#define PARAMS64_ENVSIZE     0x3f0
#define TEB32_PEB            0x30
#define PEB32_PARAMS         0x10
#define PARAMS32_CMDLINE     0x40
#define PARAMS32_ENV         0x48
#define PARAMS32_ENVSIZE     0x290

static int debug;

#define DBG(...) do { if (debug) fprintf(stderr, "onwincompat: " __VA_ARGS__); } while (0)

/* ------------------------------------------------------------------ ntdll symbols */

static void *ntdll_symbol(const char *name)
{
    static void *handle;
    static int tried;
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym) return sym;

    /* ntdll.so may have been loaded RTLD_LOCAL: open it again by path (same directory as us). */
    if (!tried)
    {
        Dl_info info;
        char self[PATH_MAX], ntdll[PATH_MAX];
        tried = 1;
        if (dladdr((const void *)ntdll_symbol, &info) && info.dli_fname)
        {
            strncpy(self, info.dli_fname, sizeof(self) - 1);
            self[sizeof(self) - 1] = 0;
            snprintf(ntdll, sizeof(ntdll), "%s/ntdll.so", dirname(self));
            handle = dlopen(ntdll, RTLD_NOLOAD | RTLD_LAZY | RTLD_LOCAL);
        }
    }
    return handle ? dlsym(handle, name) : NULL;
}

/* ------------------------------------------------------------------ small string helpers */

static int ascii_lower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

static void lower_ascii(char *s) { for (; *s; s++) *s = (char)ascii_lower((unsigned char)*s); }

static char *trim(char *s)
{
    char *e;
    while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
    e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r' || e[-1] == '\n')) *--e = 0;
    return s;
}

/* Case-insensitive glob: '*' any run of characters, '?' one character. */
static int glob_match(const char *p, const char *s)
{
    const char *star = NULL, *resume = NULL;
    while (*s)
    {
        if (*p == '*') { star = p++; resume = s; continue; }
        if (*p && (*p == '?' || ascii_lower((unsigned char)*p) == ascii_lower((unsigned char)*s)))
        {
            p++; s++;
            continue;
        }
        if (!star) return 0;
        p = star + 1;
        s = ++resume;
    }
    while (*p == '*') p++;
    return !*p;
}

static int valid_backend(const char *b)
{
    return !strcmp(b, "d3dmetal") || !strcmp(b, "dxmt") || !strcmp(b, "dxvk") || !strcmp(b, "wined3d");
}

static int is_directory(const char *path)
{
    struct stat st;
    return path && *path && !stat(path, &st) && S_ISDIR(st.st_mode);
}

/* ------------------------------------------------------------------ UTF-16 <-> UTF-8 */

static size_t wlen(const uint16_t *w) { size_t n = 0; while (w[n]) n++; return n; }

static char *utf16_to_utf8(const uint16_t *w, size_t len)
{
    char *out = malloc(len * 3 + 1), *o = out;
    size_t i;
    if (!out) return NULL;
    for (i = 0; i < len; i++)
    {
        uint32_t c = w[i];
        if (c >= 0xd800 && c < 0xdc00 && i + 1 < len && w[i + 1] >= 0xdc00 && w[i + 1] < 0xe000)
            c = 0x10000 + ((c - 0xd800) << 10) + (w[++i] - 0xdc00);
        if (c < 0x80) *o++ = (char)c;
        else if (c < 0x800) { *o++ = (char)(0xc0 | (c >> 6)); *o++ = (char)(0x80 | (c & 0x3f)); }
        else if (c < 0x10000)
        {
            *o++ = (char)(0xe0 | (c >> 12)); *o++ = (char)(0x80 | ((c >> 6) & 0x3f));
            *o++ = (char)(0x80 | (c & 0x3f));
        }
        else
        {
            *o++ = (char)(0xf0 | (c >> 18)); *o++ = (char)(0x80 | ((c >> 12) & 0x3f));
            *o++ = (char)(0x80 | ((c >> 6) & 0x3f)); *o++ = (char)(0x80 | (c & 0x3f));
        }
    }
    *o = 0;
    return out;
}

/* Writes the UTF-16 form of s (without terminator) to out if non-NULL; returns its length. */
static size_t utf8_to_utf16(const char *s, uint16_t *out)
{
    const unsigned char *p = (const unsigned char *)s;
    size_t n = 0;
    while (*p)
    {
        uint32_t c = *p++;
        int extra = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : c >= 0xc0 ? 1 : 0;
        if (extra) c &= 0x3f >> extra;
        while (extra-- > 0 && (*p & 0xc0) == 0x80) c = (c << 6) | (*p++ & 0x3f);
        if (c >= 0x10000)
        {
            if (out) { out[n] = (uint16_t)(0xd800 + ((c - 0x10000) >> 10)); out[n + 1] = (uint16_t)(0xdc00 + ((c - 0x10000) & 0x3ff)); }
            n += 2;
        }
        else { if (out) out[n] = (uint16_t)c; n++; }
    }
    return n;
}

/* ------------------------------------------------------------------ process structures */

static unsigned char *current_teb(void)
{
    nt_current_teb_fn fn = (nt_current_teb_fn)ntdll_symbol("NtCurrentTeb");
    return fn ? fn() : NULL;
}

static unsigned char *params64(void)
{
    unsigned char *teb = current_teb(), *peb;
    if (!teb || !(peb = *(unsigned char **)(teb + TEB64_PEB))) return NULL;
    return *(unsigned char **)(peb + PEB64_PARAMS);
}

/* WoW64 copy of the parameters (32-bit programs), or NULL. */
static unsigned char *params32(void)
{
    unsigned char *teb = current_teb(), *teb32;
    uint32_t peb32, p32;
    int32_t offset;
    if (!teb || !(offset = *(int32_t *)(teb + TEB64_WOWTEBOFFSET))) return NULL;
    teb32 = teb + offset;
    if (!(peb32 = *(uint32_t *)(teb32 + TEB32_PEB))) return NULL;
    p32 = *(uint32_t *)((uintptr_t)peb32 + PEB32_PARAMS);
    return p32 ? (unsigned char *)(uintptr_t)p32 : NULL;
}

/* Lowercased Windows path of this process's exe, '\' separators, without "\\?\" / "\??\". */
static char *image_path(void)
{
    unsigned char *params = params64();
    char *path = NULL, *start;

    if (params)
    {
        uint16_t len = *(uint16_t *)(params + PARAMS64_IMAGEPATH);
        const uint16_t *buf = *(const uint16_t **)(params + PARAMS64_IMAGEPATH + 8);
        if (buf && len) path = utf16_to_utf8(buf, len / 2);
    }
    if (!path)
    {
        /* Fallback: the loader's argv ("wine", "C:\...\game.exe", ...). */
        char **argv = *_NSGetArgv();
        int argc = *_NSGetArgc();
        if (argc > 1 && argv[1]) path = strdup(argv[1]);
    }
    if (!path) return NULL;
    for (start = path; *start; start++) if (*start == '/') *start = '\\';
    lower_ascii(path);
    start = path;
    if (!strncmp(start, "\\\\?\\", 4) || !strncmp(start, "\\??\\", 4)) start += 4;
    if (start != path) memmove(path, start, strlen(start) + 1);
    return path;
}

/* ------------------------------------------------------------------ command line */

/* This process's Windows command line (UTF-8), or NULL. */
static char *command_line(void)
{
    unsigned char *params = params64();
    uint16_t len;
    const uint16_t *buf;
    if (!params) return NULL;
    len = *(uint16_t *)(params + PARAMS64_CMDLINE);
    buf = *(const uint16_t **)(params + PARAMS64_CMDLINE + 8);
    return (buf && len) ? utf16_to_utf8(buf, len / 2) : strdup("");
}

/* Allocates a NUL-terminated UTF-16 copy of "<old> <extra>" below zero_bits; returns length in bytes. */
static uint16_t *build_cmdline(const uint16_t *old, size_t old_chars, const char *extra, uintptr_t zero_bits,
                               uint16_t *bytes_out)
{
    nt_allocate_virtual_memory_fn alloc =
        (nt_allocate_virtual_memory_fn)ntdll_symbol("NtAllocateVirtualMemory");
    size_t extra_chars = utf8_to_utf16(extra, NULL), chars = old_chars + 1 + extra_chars, size;
    uint16_t *buf = NULL;

    if (!alloc || (chars + 1) * 2 > 0xfffe) return NULL;
    size = (chars + 1) * sizeof(uint16_t);
    if (alloc((void *)~(uintptr_t)0, (void **)&buf, zero_bits, &size, 0x3000, 0x04) || !buf) return NULL;
    if (old_chars) memcpy(buf, old, old_chars * sizeof(uint16_t));
    buf[old_chars] = ' ';
    utf8_to_utf16(extra, buf + old_chars + 1);
    buf[chars] = 0;
    *bytes_out = (uint16_t)(chars * sizeof(uint16_t));
    return buf;
}

/* Appends arguments to this process's command line (CompatRule.appendArguments)
 * (Chromium launchers need --in-process-gpu etc. under winemac). Both the 64-bit parameters and the
 * WoW64 copy are updated; kernelbase reads them later for GetCommandLineW / __wgetmainargs. */
static void append_command_line(const char *extra)
{
    unsigned char *p64 = params64(), *p32 = params32();
    uint16_t bytes, *buf;

    if (!extra || !*extra || !p64) return;
    {
        uint16_t len = *(uint16_t *)(p64 + PARAMS64_CMDLINE);
        const uint16_t *old = *(const uint16_t **)(p64 + PARAMS64_CMDLINE + 8);
        if ((buf = build_cmdline(old, old ? len / 2 : 0, extra, 0, &bytes)))
        {
            *(uint16_t *)(p64 + PARAMS64_CMDLINE) = bytes;
            *(uint16_t *)(p64 + PARAMS64_CMDLINE + 2) = bytes + 2;
            *(uint16_t **)(p64 + PARAMS64_CMDLINE + 8) = buf;
        }
    }
    if (p32)
    {
        uint16_t len = *(uint16_t *)(p32 + PARAMS32_CMDLINE);
        const uint16_t *old = (const uint16_t *)(uintptr_t)*(uint32_t *)(p32 + PARAMS32_CMDLINE + 4);
        if ((buf = build_cmdline(old, old ? len / 2 : 0, extra, 0x7fffffff, &bytes)))
        {
            *(uint16_t *)(p32 + PARAMS32_CMDLINE) = bytes;
            *(uint16_t *)(p32 + PARAMS32_CMDLINE + 2) = bytes + 2;
            *(uint32_t *)(p32 + PARAMS32_CMDLINE + 4) = (uint32_t)(uintptr_t)buf;
        }
    }
    DBG("command line += %s%s\n", extra, p32 ? " (wow64 too)" : "");
}

/* ------------------------------------------------------------------ Windows environment */

static char **pe_env;
static size_t pe_count, pe_cap;
static int pe_loaded, pe_changed, pe_broken;

static void pe_load(void)
{
    unsigned char *params = params64();
    const uint16_t *env, *p;

    pe_loaded = 1;
    if (!params || !(env = *(const uint16_t **)(params + PARAMS64_ENV))) return;
    for (p = env; *p; p += wlen(p) + 1)
    {
        char *s;
        if (pe_count == pe_cap)
        {
            size_t cap = pe_cap ? pe_cap * 2 : 128;
            char **n = realloc(pe_env, cap * sizeof(*n));
            /* out of memory: a partial copy must never replace the real block (pe_commit) */
            if (!n) { pe_broken = 1; return; }
            pe_env = n;
            pe_cap = cap;
        }
        if (!(s = utf16_to_utf8(p, wlen(p)))) { pe_broken = 1; return; }
        pe_env[pe_count++] = s;
    }
}

/* Length of the name part of "NAME=value" (a leading '=' belongs to the name, as in "=C:"). */
static size_t env_name_len(const char *entry)
{
    const char *eq = strchr(entry + (entry[0] == '='), '=');
    return eq ? (size_t)(eq - entry) : strlen(entry);
}

/* Index of NAME=... (case-insensitive, as Windows). strncasecmp first, so pe_env[i][n] is inside
 * the string; entries without '=' never match, so pe_env[i] + n + 1 is always valid. */
static long pe_find(const char *name)
{
    size_t i, n = strlen(name);
    for (i = 0; i < pe_count; i++)
        if (!strncasecmp(pe_env[i], name, n) && pe_env[i][n] == '=' && env_name_len(pe_env[i]) == n)
            return (long)i;
    return -1;
}

static const char *pe_get(const char *name)
{
    long i = pe_find(name);
    return i < 0 ? NULL : pe_env[i] + strlen(name) + 1;
}

static void pe_set(const char *name, const char *value)
{
    long i = pe_find(name);
    char *entry;
    if (i >= 0 && !strcmp(pe_env[i] + strlen(name) + 1, value)) return;
    if (!(entry = malloc(strlen(name) + strlen(value) + 2))) return;
    sprintf(entry, "%s=%s", name, value);
    if (i >= 0)
    {
        free(pe_env[i]);
        pe_env[i] = entry;
    }
    else
    {
        if (pe_count == pe_cap)
        {
            size_t cap = pe_cap ? pe_cap * 2 : 128;
            char **n = realloc(pe_env, cap * sizeof(*n));
            if (!n) { free(entry); return; }
            pe_env = n;
            pe_cap = cap;
        }
        pe_env[pe_count++] = entry;
    }
    pe_changed = 1;
}

static void pe_unset(const char *name)
{
    long i = pe_find(name);
    if (i < 0) return;
    free(pe_env[i]);
    memmove(pe_env + i, pe_env + i + 1, (pe_count - i - 1) * sizeof(*pe_env));
    pe_count--;
    pe_changed = 1;
}

static uint16_t *pe_build_block(uintptr_t zero_bits, size_t *bytes)
{
    nt_allocate_virtual_memory_fn alloc =
        (nt_allocate_virtual_memory_fn)ntdll_symbol("NtAllocateVirtualMemory");
    size_t total = 1, i, size;
    uint16_t *block = NULL, *w;

    if (!alloc) return NULL;
    for (i = 0; i < pe_count; i++) total += utf8_to_utf16(pe_env[i], NULL) + 1;
    size = total * sizeof(uint16_t);
    /* MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE, current process */
    if (alloc((void *)~(uintptr_t)0, (void **)&block, zero_bits, &size, 0x3000, 0x04) || !block)
        return NULL;
    for (w = block, i = 0; i < pe_count; i++)
    {
        w += utf8_to_utf16(pe_env[i], w);
        *w++ = 0;
    }
    *w = 0;
    *bytes = total * sizeof(uint16_t);
    return block;
}

/* Installs the edited environment as this process's environment block (64-bit and WoW64). */
static void pe_commit(void)
{
    unsigned char *p64 = params64(), *p32 = params32();
    uint16_t *block;
    size_t bytes;

    if (!pe_changed || pe_broken || !p64) return;
    if ((block = pe_build_block(0, &bytes)))
    {
        *(uint16_t **)(p64 + PARAMS64_ENV) = block;
        *(uint64_t *)(p64 + PARAMS64_ENVSIZE) = bytes;
    }
    if (p32 && (block = pe_build_block(0x7fffffff, &bytes)))
    {
        *(uint32_t *)(p32 + PARAMS32_ENV) = (uint32_t)(uintptr_t)block;
        *(uint32_t *)(p32 + PARAMS32_ENVSIZE) = (uint32_t)bytes;
    }
    DBG("windows environment updated (%zu variables%s)\n", pe_count, p32 ? ", wow64" : "");
}

/* ------------------------------------------------------------------ both environments */

/* Undo what a parent's rule changed: every ONWIN_COMPAT_ORIG_<KEY> restores KEY. */
static void restore_unix(void)
{
    char **environ_ = *_NSGetEnviron();
    char *names[256];
    int n = 0, i;
    for (i = 0; environ_[i] && n < 256; i++)
        if (!strncmp(environ_[i], ORIG_PREFIX, sizeof(ORIG_PREFIX) - 1))
            names[n++] = strndup(environ_[i], env_name_len(environ_[i]));
    for (i = 0; i < n; i++)
    {
        const char *orig, *key;
        if (!names[i]) continue;
        key = names[i] + sizeof(ORIG_PREFIX) - 1;
        orig = getenv(names[i]);
        if (*key && orig)
        {
            if (orig[0] == '+') setenv(key, orig + 1, 1);
            else unsetenv(key);
        }
        unsetenv(names[i]);
        free(names[i]);
    }
}

static void restore_pe(void)
{
    size_t i = 0;
    while (i < pe_count)
    {
        if (!strncasecmp(pe_env[i], ORIG_PREFIX, sizeof(ORIG_PREFIX) - 1))
        {
            char *entry = pe_env[i];
            char *key = strndup(entry + sizeof(ORIG_PREFIX) - 1,
                                env_name_len(entry) - (sizeof(ORIG_PREFIX) - 1));
            const char *orig = entry + env_name_len(entry);
            orig = *orig ? orig + 1 : "-";
            /* drop the marker first: pe_set/pe_unset may move entries */
            memmove(pe_env + i, pe_env + i + 1, (pe_count - i - 1) * sizeof(*pe_env));
            pe_count--;
            pe_changed = 1;
            if (key && *key)
            {
                if (orig[0] == '+') pe_set(key, orig + 1);
                else pe_unset(key);
            }
            free(key);
            free(entry);
            i = 0;  /* the array changed */
            continue;
        }
        i++;
    }
}

/* Sets a rule variable in both environments, remembering the original value for children. */
static void set_rule_var(const char *key, const char *value)
{
    char marker[512], *saved;
    const char *orig;

    if (strlen(key) + sizeof(ORIG_PREFIX) > sizeof(marker)) return;
    snprintf(marker, sizeof(marker), ORIG_PREFIX "%s", key);

    if (!getenv(marker))
    {
        orig = getenv(key);
        if ((saved = malloc((orig ? strlen(orig) : 0) + 2)))
        {
            sprintf(saved, "%s%s", orig ? "+" : "-", orig ? orig : "");
            setenv(marker, saved, 1);
            free(saved);
        }
    }
    setenv(key, value, 1);

    if (!pe_get(marker))
    {
        orig = pe_get(key);
        if ((saved = malloc((orig ? strlen(orig) : 0) + 2)))
        {
            sprintf(saved, "%s%s", orig ? "+" : "-", orig ? orig : "");
            pe_set(marker, saved);
            free(saved);
        }
    }
    pe_set(key, value);
}

/* ------------------------------------------------------------------ rules */

struct decision
{
    char backend[16];        /* "" = no rule chose one */
    int backend_line;
    char *env_keys[MAX_RULE_ENV];
    char *env_values[MAX_RULE_ENV];
    int env_count;
    char append[2048];       /* arguments to append to the command line */
};

static char *process_cmdline;  /* lowercase, for forbid= checks */

/* forbid=<substr>[|<substr>...]: the rule is skipped when the command line contains one of them. */
static int forbidden(char *list)
{
    char *save = NULL, *tok;
    if (!process_cmdline) return 0;
    for (tok = strtok_r(list, "|", &save); tok; tok = strtok_r(NULL, "|", &save))
    {
        char *t = trim(tok);
        lower_ascii(t);
        if (*t && strstr(process_cmdline, t)) return 1;
    }
    return 0;
}

/* Splits a rule line at unescaped ';' (in place; "\;" → ';'). Returns the number of fields. */
static int split_fields(char *line, char **fields, int max)
{
    int n = 0;
    char *r = line, *w = line;
    fields[n++] = w;
    while (*r)
    {
        if (r[0] == '\\' && r[1] == ';') { *w++ = ';'; r += 2; continue; }
        if (*r == ';')
        {
            *w++ = 0;
            r++;
            if (n == max) break;
            fields[n++] = w;
            continue;
        }
        *w++ = *r++;
    }
    *w = 0;
    return n;
}

static int exe_matches(char *patterns, const char *path, const char *name)
{
    char *save = NULL, *pat;
    for (pat = strtok_r(patterns, "|", &save); pat; pat = strtok_r(NULL, "|", &save))
    {
        char *p = trim(pat), *c;
        if (!*p) continue;
        for (c = p; *c; c++) if (*c == '/') *c = '\\';
        if (strchr(p, '\\') || strchr(p, ':') ? glob_match(p, path) : glob_match(p, name)) return 1;
    }
    return 0;
}

static void apply_rule_line(char *line, int lineno, const char *path, const char *name, struct decision *d)
{
    char *fields[96];
    char *exe = NULL, *backend = NULL, *append = NULL, *forbid = NULL;
    int n = split_fields(line, fields, 96), i;

    for (i = 0; i < n; i++)
    {
        char *f = trim(fields[i]);
        if (!strncmp(f, "exe=", 4)) exe = f + 4;
        else if (!strncmp(f, "backend=", 8)) backend = trim(f + 8);
        else if (!strncmp(f, "append=", 7)) append = trim(f + 7);
        else if (!strncmp(f, "forbid=", 7)) forbid = f + 7;
    }
    if (!exe || !exe_matches(exe, path, name)) return;
    if (forbid && forbidden(forbid))
    {
        DBG("rule at line %d matches but is forbidden for this command line\n", lineno);
        return;
    }
    DBG("rule at line %d matches\n", lineno);

    if (append && *append)
    {
        /* Skip arguments the program already has (e.g. passed down to a child by its parent). */
        char low[2048];
        snprintf(low, sizeof(low), "%s", append);
        lower_ascii(low);
        if (!process_cmdline || !strstr(process_cmdline, low))
        {
            size_t used = strlen(d->append);
            snprintf(d->append + used, sizeof(d->append) - used, "%s%s", used ? " " : "", append);
        }
    }

    if (backend && !d->backend[0] && strcmp(backend, "auto"))
    {
        lower_ascii(backend);
        if (valid_backend(backend))
        {
            snprintf(d->backend, sizeof(d->backend), "%s", backend);
            d->backend_line = lineno;
        }
        else DBG("line %d: unknown backend '%s'\n", lineno, backend);
    }
    for (i = 0; i < n; i++)
    {
        char *f = trim(fields[i]), *eq;
        int j, known = 0;
        if (strncmp(f, "env:", 4) || !(eq = strchr(f + 4, '=')) || eq == f + 4) continue;
        *eq = 0;
        for (j = 0; j < d->env_count; j++) if (!strcmp(d->env_keys[j], f + 4)) known = 1;
        if (known || d->env_count == MAX_RULE_ENV) continue;
        d->env_keys[d->env_count] = strdup(f + 4);
        d->env_values[d->env_count] = strdup(eq + 1);
        if (d->env_keys[d->env_count] && d->env_values[d->env_count]) d->env_count++;
    }
}

static void read_rules(const char *file, const char *path, const char *name, struct decision *d)
{
    FILE *f;
    char *line = NULL;
    size_t cap = 0;
    int lineno = 0;

    if (!file || !*file) return;
    if (!(f = fopen(file, "r")))
    {
        DBG("no rules file %s\n", file);
        return;
    }
    while (getline(&line, &cap, f) > 0)
    {
        char *l = trim(line);
        lineno++;
        if (!*l || *l == '#') continue;
        apply_rule_line(l, lineno, path, name, d);
    }
    free(line);
    fclose(f);
}

/* ------------------------------------------------------------------ DLL paths */

static void prepend_list(prepend_dll_path_fn prepend, const char *list)
{
    char *copy, *tok, *save = NULL, *items[MAX_PATHS];
    int count = 0, i;

    if (!list || !*list || !(copy = strdup(list))) return;
    for (tok = strtok_r(copy, ":", &save); tok && count < MAX_PATHS; tok = strtok_r(NULL, ":", &save))
        if (*tok) items[count++] = tok;

    /* prepend_dll_path() puts its argument first, so walk the list backwards to keep the
     * caller's priority order. The strings are intentionally leaked: ntdll keeps the pointers. */
    for (i = count - 1; i >= 0; i--)
    {
        char *p = strdup(items[i]);
        if (!p) continue;
        prepend(p);
        DBG("dll path += %s\n", p);
    }
    free(copy);
}

/* ------------------------------------------------------------------ entry point */

__attribute__((constructor))
static void onwincompat_init(void)
{
    const char *default_backend, *default_paths, *chosen, *paths;
    char *path, *name, *slash, envname[64];
    struct decision d;
    prepend_dll_path_fn prepend;
    int i;

    {
        const char *v = getenv("ONWIN_COMPAT_DEBUG");
        debug = v && *v && strcmp(v, "0");
    }
    memset(&d, 0, sizeof(d));

    restore_unix();
    pe_load();
    restore_pe();

    /* Read only now: restore_unix() may have changed (and freed) these strings. */
    default_backend = getenv("ONWIN_BACKEND_DEFAULT");
    default_paths = getenv("ONWIN_DLL_PATHS");

    path = image_path();
    name = path ? ((slash = strrchr(path, '\\')) ? slash + 1 : path) : NULL;
    if ((process_cmdline = command_line())) lower_ascii(process_cmdline);
    DBG("process %s\n", path ? path : "(unknown)");
    if (path) read_rules(getenv("ONWIN_COMPAT_RULES"), path, name, &d);

    if (default_backend && !valid_backend(default_backend)) default_backend = NULL;
    chosen = default_backend;
    paths = default_paths;
    if (d.backend[0] && (!default_backend || strcmp(d.backend, default_backend)))
    {
        const char *dir = NULL;
        if (strcmp(d.backend, "wined3d"))
        {
            snprintf(envname, sizeof(envname), "ONWIN_BACKEND_DIR_%s", d.backend);
            dir = getenv(envname);
        }
        if (!strcmp(d.backend, "wined3d") || is_directory(dir))
        {
            chosen = d.backend;
            paths = dir;
            DBG("line %d: backend %s\n", d.backend_line, d.backend);
        }
        else DBG("line %d: backend %s is not available, keeping %s\n", d.backend_line, d.backend,
                 default_backend ? default_backend : "the default");
    }
    else if (d.backend[0]) DBG("line %d: backend %s (= default)\n", d.backend_line, d.backend);

    if (paths && *paths)
    {
        if ((prepend = (prepend_dll_path_fn)ntdll_symbol("prepend_dll_path"))) prepend_list(prepend, paths);
        else fprintf(stderr, "onwincompat: prepend_dll_path() not found, graphics backend not applied\n");
    }

    /* Older launchers set only ONWIN_DLL_PATHS: then the backend is unknown, keep what is there. */
    if (!chosen && !(paths && *paths)) chosen = "wined3d";
    if (chosen)
    {
        setenv("CX_ACTIVE_GRAPHICS_BACKEND", chosen, 1);
        if (pe_loaded) pe_set("CX_ACTIVE_GRAPHICS_BACKEND", chosen);
        DBG("CX_ACTIVE_GRAPHICS_BACKEND=%s\n", chosen);
    }

    for (i = 0; i < d.env_count; i++)
    {
        set_rule_var(d.env_keys[i], d.env_values[i]);
        DBG("env %s=%s\n", d.env_keys[i], d.env_values[i]);
        free(d.env_keys[i]);
        free(d.env_values[i]);
    }

    if (d.append[0]) append_command_line(d.append);
    free(process_cmdline);
    process_cmdline = NULL;

    pe_commit();
    for (i = 0; i < (int)pe_count; i++) free(pe_env[i]);
    free(pe_env);
    pe_env = NULL;
    pe_count = pe_cap = 0;
    free(path);
}
