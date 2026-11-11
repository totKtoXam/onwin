/* d3dpresent — draws real frames through D3D11 + DXGI swapchain for ~10 s (like a game).
 * The window cycles red → green → blue; its title names the adapter. Exit code 0 = all Present() calls OK.
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3dpresent.exe d3dpresent.c -ld3d11 -ldxgi -luuid -lgdi32 -luser32 -mwindows */
#define COBJMACROS
#include <windows.h>
#include <stdio.h>
#include <d3d11.h>
#include <dxgi.h>

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(h, m, w, l);
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    WNDCLASSA wc = {0};
    DXGI_SWAP_CHAIN_DESC sd = {0};
    IDXGISwapChain *sc = NULL; ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL;
    ID3D11Texture2D *bb = NULL; ID3D11RenderTargetView *rtv = NULL;
    D3D_FEATURE_LEVEL fl; HRESULT hr; HWND hwnd; DWORD start; int frames = 0, failures = 0;
    char title[256];
    FILE *log = fopen("d3dpresent.log", "w");

    wc.lpfnWndProc = wndproc; wc.hInstance = inst; wc.lpszClassName = "onwinpresent";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassA(&wc);
    hwnd = CreateWindowA("onwinpresent", "onwin: проверка графики", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                         200, 200, 640, 400, NULL, NULL, inst, NULL);
    sd.BufferCount = 2; sd.BufferDesc.Width = 640; sd.BufferDesc.Height = 400;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd; sd.SampleDesc.Count = 1; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                       &sd, &sc, &dev, &fl, &ctx);
    if (log) fprintf(log, "D3D11CreateDeviceAndSwapChain hr=0x%08lx fl=0x%x\n", (unsigned long)hr, (unsigned)fl);
    if (FAILED(hr)) { if (log) fclose(log); return 2; }
    {
        IDXGIDevice *dxgi; IDXGIAdapter *ad; DXGI_ADAPTER_DESC desc;
        ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi);
        IDXGIDevice_GetAdapter(dxgi, &ad); IDXGIAdapter_GetDesc(ad, &desc);
        snprintf(title, sizeof(title), "onwin: проверка графики — %ls", desc.Description);
        SetWindowTextA(hwnd, title);
    }
    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
    start = GetTickCount();
    while (GetTickCount() - start < 10000)
    {
        MSG msg; float t = (GetTickCount() - start) / 1000.0f;
        float color[4] = {0, 0, 0, 1};
        int phase = ((int)(t / 1.5f)) % 3;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        color[phase] = 0.9f;
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, color);
        hr = IDXGISwapChain_Present(sc, 1, 0);
        if (FAILED(hr)) failures++;
        frames++;
    }
    if (log) { fprintf(log, "frames=%d failures=%d seconds=10\n", frames, failures); fclose(log); }
    return failures ? 1 : 0;
}
