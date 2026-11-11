/* d3dprobe — проверка графического стека onwin.
 * Создаёт устройство Direct3D 11 (и при наличии — Direct3D 12), печатает адаптер, feature level
 * и путь к реально загруженным d3d11.dll / dxgi.dll / d3d12.dll (по нему видно, какой бэкенд
 * подставил onwincompat: lib/dxmt, lib/dxvk, Graphics/D3DMetal или встроенный wined3d).
 *
 * Сборка: x86_64-w64-mingw32-gcc -O2 -o d3dprobe.exe d3dprobe.c -ld3d11 -ldxgi -luuid
 */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d11.h>
#include <dxgi.h>

static void print_module(const char *name)
{
    HMODULE h = GetModuleHandleA(name);
    char path[MAX_PATH] = "";
    if (!h) { printf("  %-10s не загружен\n", name); return; }
    GetModuleFileNameA(h, path, sizeof(path));
    /* Wine показывает builtin-DLL как C:\windows\system32\..., поэтому дополнительно
     * спрашиваем у Wine настоящий Unix-путь через wine_get_unix_file_name — его нет в
     * заголовках, ищем динамически. */
    printf("  %-10s %s\n", name, path);
}

typedef HRESULT (WINAPI *PFN_D3D12CreateDevice)(IUnknown *, int, REFIID, void **);
DEFINE_GUID(IID_ID3D12Device_local, 0x189819f1, 0x1db6, 0x4b57, 0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7);

int main(void)
{
    /* Как в игре: сначала окно — тогда Wine загружает Mac-драйвер (winemac.so), на который
     * опираются DXMT (winemetal.so) и D3DMetal. */
    HWND hwnd = CreateWindowExA(0, "STATIC", "onwin d3dprobe", WS_OVERLAPPEDWINDOW, 0, 0, 320, 240,
                                NULL, NULL, GetModuleHandleA(NULL), NULL);
    printf("Окно: %s\n", hwnd ? "создано" : "не создано");
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *ctx = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &device, &fl, &ctx);
    printf("D3D11CreateDevice: hr=0x%08lx feature_level=0x%x\n", (unsigned long)hr, (unsigned)fl);
    if (SUCCEEDED(hr))
    {
        IDXGIDevice *dxgi_dev = NULL;
        if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_dev)))
        {
            IDXGIAdapter *adapter = NULL;
            if (SUCCEEDED(IDXGIDevice_GetAdapter(dxgi_dev, &adapter)))
            {
                DXGI_ADAPTER_DESC desc;
                if (SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &desc)))
                    printf("Адаптер: %ls (vendor 0x%04x, VRAM %llu МБ)\n", desc.Description,
                           desc.VendorId, (unsigned long long)desc.DedicatedVideoMemory >> 20);
                IDXGIAdapter_Release(adapter);
            }
            IDXGIDevice_Release(dxgi_dev);
        }
        ID3D11DeviceContext_Release(ctx);
        ID3D11Device_Release(device);
    }

    HMODULE d3d12 = LoadLibraryA("d3d12.dll");
    if (d3d12)
    {
        PFN_D3D12CreateDevice create = (PFN_D3D12CreateDevice)GetProcAddress(d3d12, "D3D12CreateDevice");
        void *dev12 = NULL;
        if (create)
        {
            hr = create(NULL, 0xb000 /* D3D_FEATURE_LEVEL_11_0 */, &IID_ID3D12Device_local, &dev12);
            printf("D3D12CreateDevice: hr=0x%08lx\n", (unsigned long)hr);
            if (dev12) ((IUnknown *)dev12)->lpVtbl->Release((IUnknown *)dev12);
        }
    }

    printf("Загруженные модули:\n");
    print_module("d3d11.dll");
    print_module("dxgi.dll");
    print_module("d3d12.dll");
    print_module("winemetal.dll");
    print_module("wined3d.dll");
    return 0;
}
