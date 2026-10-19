#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <d3d11_3.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

/* God of War depth proxy for CrossOver's D3DMetal and DXMT backends.
 *
 * Build: make (requires Homebrew mingw-w64).
 * Verification: make verify.exe, then run it in this directory through the
 * chosen CrossOver bottle with a native,builtin d3d11 override.
 * Deployment: select the graphics backend in CrossOver, place this d3d11.dll
 * beside GoW.exe, and set the game's Wine AppDefaults DLL override to
 * d3d11=native,builtin. The proxy loads the selected backend through Wine's
 * system-directory d3d11.dll, keeping it matched to the installed runtime.
 *
 * gow_proxy_depth.txt beside this DLL selects 0 (original) or 2 (GREATER_EQUAL
 * variants for EQUAL states). Default: 2. Changes are sampled every 250 ms
 * on state binding; deferred command lists capture the mode when recorded.
 * OMGetDepthStencilState reports the state actually bound to the backend.
 *
 * These backends share one vtable across D3D11 device interface versions.
 * No COM object is wrapped or given a different identity.
 * The depth comparison relaxation may affect occlusion; verify the game
 * visually before relying on it. */
static const GUID variant_key = {0xb3587386, 0x4ada, 0x4ad2,
    {0xa3, 0xb7, 0x1a, 0x89, 0xc2, 0xa4, 0xeb, 0x91}};
static HMODULE self_module, backend;
static INIT_ONCE init_once = INIT_ONCE_STATIC_INIT;
static WCHAR mode_path[32768];
static _Atomic int mode = 2;
static _Atomic ULONGLONG next_poll;

#define SLOT(type, member) (offsetof(type, member) / sizeof(void *))
typedef struct {
    size_t slot;
    void *replacement;
    void *original;
} Hook;
typedef struct Table {
    void **vtable;
    Hook hooks[5];
    struct Table *next;
} Table;
static _Atomic(Table *) tables;
static SRWLOCK table_lock = SRWLOCK_INIT;

static Table *find_table(void *object) {
    void **vtable = *(void ***)object;
    for (Table *t = atomic_load_explicit(&tables, memory_order_acquire); t; t = t->next)
        if (t->vtable == vtable) return t;
    /* Only installed vtables can call a hook. */
    RaiseFailFastException(NULL, NULL, 0);
    return NULL;
}

/* Records are immutable after publication. One is retained per backend vtable,
 * not per device/state/context. The DLL is pinned because these callbacks must
 * remain valid until the process exits. Hot-path lookups allocate nothing. */
static HRESULT install_hooks(void *object, const Hook *hooks, size_t count) {
    HRESULT result = S_OK;
    void **vtable = *(void ***)object;
    AcquireSRWLockExclusive(&table_lock);
    for (Table *t = atomic_load_explicit(&tables, memory_order_relaxed); t; t = t->next)
        if (t->vtable == vtable) goto done;
    Table *record = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*record));
    if (!record) { result = E_OUTOFMEMORY; goto done; }
    record->vtable = vtable;
    size_t last_slot = 0;
    for (size_t i = 0; i < count; ++i) {
        record->hooks[i] = hooks[i];
        record->hooks[i].original = vtable[hooks[i].slot];
        if (hooks[i].slot > last_slot) last_slot = hooks[i].slot;
    }
    DWORD previous = 0;
    SIZE_T bytes = (last_slot + 1) * sizeof(void *);
    /* These are static vtables in a retained backend, not arbitrary caller
     * buffers. Installation is serialized and their mapping stays alive.
     * D3DMetal's writable Mach-O pages are outside Wine's VirtualQuery/
     * VirtualProtect bookkeeping. Use Wine's guarded write probe to recognize
     * already-writable tables; change protection only for read-only PE tables. */
    BOOL change_protection = IsBadWritePtr(vtable, bytes);
    if (change_protection && !VirtualProtect(vtable, bytes, PAGE_READWRITE, &previous)) {
        result = HRESULT_FROM_WIN32(GetLastError());
        HeapFree(GetProcessHeap(), 0, record);
        goto done;
    }
    record->next = atomic_load_explicit(&tables, memory_order_relaxed);
    atomic_store_explicit(&tables, record, memory_order_release);
    for (size_t i = 0; i < count; ++i)
        InterlockedExchangePointer(&vtable[hooks[i].slot], hooks[i].replacement);
    DWORD ignored;
    if (change_protection && !VirtualProtect(vtable, bytes, previous, &ignored))
        OutputDebugStringA("gow-depth-proxy: could not restore vtable protection\n");
done:
    ReleaseSRWLockExclusive(&table_lock);
    return result;
}

static void poll_mode(void) {
    ULONGLONG now = GetTickCount64();
    ULONGLONG expected = atomic_load_explicit(&next_poll, memory_order_relaxed);
    if (now < expected || !atomic_compare_exchange_strong_explicit(
            &next_poll, &expected, now + 250, memory_order_relaxed, memory_order_relaxed))
        return;
    HANDLE file = CreateFileW(mode_path, GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    char text[32];
    DWORD length = 0;
    BOOL read_ok = ReadFile(file, text, sizeof(text), &length, NULL);
    CloseHandle(file);
    if (!read_ok || length == 0 || length == sizeof(text)) return;
    DWORD start = 0, end = length;
    while (start < end && (text[start] == ' ' || text[start] == '\r' ||
            text[start] == '\n' || text[start] == '\t')) ++start;
    while (end > start && (text[end-1] == ' ' || text[end-1] == '\r' ||
            text[end-1] == '\n' || text[end-1] == '\t')) --end;
    if (end - start == 1 && (text[start] == '0' || text[start] == '2'))
        atomic_store_explicit(&mode, text[start] - '0', memory_order_relaxed);
}

typedef HRESULT (STDMETHODCALLTYPE *CreateDepth)(ID3D11Device *,
    const D3D11_DEPTH_STENCIL_DESC *, ID3D11DepthStencilState **);
typedef void (STDMETHODCALLTYPE *SetDepth)(ID3D11DeviceContext *,
    ID3D11DepthStencilState *, UINT);
typedef HRESULT (STDMETHODCALLTYPE *CreateDeferred)(ID3D11Device *, UINT,
    ID3D11DeviceContext **);

static HRESULT STDMETHODCALLTYPE create_depth(ID3D11Device *device,
        const D3D11_DEPTH_STENCIL_DESC *desc, ID3D11DepthStencilState **output) {
    CreateDepth original = (CreateDepth)find_table(device)->hooks[0].original;
    HRESULT result = original(device, desc, output);
    if (FAILED(result) || !output || !*output || !desc ||
            desc->DepthFunc != D3D11_COMPARISON_EQUAL) return result;
    ID3D11DepthStencilState *variant = NULL;
    UINT bytes = sizeof(variant);
    if (SUCCEEDED(ID3D11DepthStencilState_GetPrivateData(*output,
            &variant_key, &bytes, &variant))) {
        ID3D11DepthStencilState_Release(variant);
        return result;
    }
    D3D11_DEPTH_STENCIL_DESC patched = *desc;
    patched.DepthFunc = D3D11_COMPARISON_GREATER_EQUAL;
    HRESULT patch_result = original(device, &patched, &variant);
    if (SUCCEEDED(patch_result)) {
        /* The original owns the variant. Bound contexts/command lists retain
         * their own references, so releasing a caller's state is always safe. */
        patch_result = ID3D11DepthStencilState_SetPrivateDataInterface(*output,
            &variant_key, (IUnknown *)variant);
        ID3D11DepthStencilState_Release(variant);
    }
    if (FAILED(patch_result)) {
        ID3D11DepthStencilState_Release(*output);
        *output = NULL;
        return patch_result;
    }
    return result;
}

static void STDMETHODCALLTYPE set_depth(ID3D11DeviceContext *context,
        ID3D11DepthStencilState *state, UINT stencil_ref) {
    SetDepth original = (SetDepth)find_table(context)->hooks[0].original;
    poll_mode();
    ID3D11DepthStencilState *variant = NULL;
    if (state && atomic_load_explicit(&mode, memory_order_relaxed) == 2) {
        UINT bytes = sizeof(variant);
        ID3D11DepthStencilState_GetPrivateData(state, &variant_key, &bytes, &variant);
    }
    original(context, variant ? variant : state, stencil_ref);
    if (variant) ID3D11DepthStencilState_Release(variant);
}

static HRESULT hook_context(ID3D11DeviceContext *context) {
    const Hook hooks[] = {{SLOT(ID3D11DeviceContextVtbl, OMSetDepthStencilState),
        (void *)set_depth, NULL}};
    return install_hooks(context, hooks, 1);
}

static HRESULT deferred_common(ID3D11Device *device, UINT flags,
        ID3D11DeviceContext **output, unsigned version) {
    CreateDeferred original = (CreateDeferred)find_table(device)->hooks[version + 1].original;
    HRESULT result = original(device, flags, output);
    if (SUCCEEDED(result) && output && *output) {
        HRESULT hooked = hook_context(*output);
        if (FAILED(hooked)) {
            ID3D11DeviceContext_Release(*output);
            *output = NULL;
            return hooked;
        }
    }
    return result;
}
#define DEFERRED(version) \
    static HRESULT STDMETHODCALLTYPE deferred##version(ID3D11Device *device, \
            UINT flags, ID3D11DeviceContext **output) { \
        return deferred_common(device, flags, output, version); \
    }
DEFERRED(0)
DEFERRED(1)
DEFERRED(2)
DEFERRED(3)

static HRESULT hook_device(ID3D11Device *device) {
    ID3D11Device3 *device3 = NULL;
    HRESULT result = ID3D11Device_QueryInterface(device, &IID_ID3D11Device3, (void **)&device3);
    if (FAILED(result)) return result;
    BOOL same_table = *(void ***)device3 == *(void ***)device;
    ID3D11Device3_Release(device3);
    if (!same_table) return E_NOINTERFACE;
    const Hook hooks[] = {
        {SLOT(ID3D11Device3Vtbl, CreateDepthStencilState), (void *)create_depth, NULL},
        {SLOT(ID3D11Device3Vtbl, CreateDeferredContext), (void *)deferred0, NULL},
        {SLOT(ID3D11Device3Vtbl, CreateDeferredContext1), (void *)deferred1, NULL},
        {SLOT(ID3D11Device3Vtbl, CreateDeferredContext2), (void *)deferred2, NULL},
        {SLOT(ID3D11Device3Vtbl, CreateDeferredContext3), (void *)deferred3, NULL}
    };
    result = install_hooks(device, hooks, sizeof(hooks) / sizeof(hooks[0]));
    if (FAILED(result)) return result;
    ID3D11DeviceContext *context = NULL;
    ID3D11Device_GetImmediateContext(device, &context);
    result = hook_context(context);
    ID3D11DeviceContext_Release(context);
    return result;
}

static BOOL CALLBACK initialize(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once; (void)parameter; (void)context;
    WCHAR path[32768];
    DWORD length = GetModuleFileNameW(self_module, path, 32768);
    if (!length || length >= 32768) return FALSE;
    WCHAR *name = wcsrchr(path, L'\\');
    if (!name || name - path + 32 >= 32768) return FALSE;
    ++name;
    wcscpy(name, L"gow_proxy_depth.txt");
    wcscpy(mode_path, path);
    UINT system_length = GetSystemDirectoryW(path, 32768);
    if (!system_length || system_length + 11 >= 32768) return FALSE;
    wcscat(path, L"\\d3d11.dll");
    backend = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!backend) return FALSE;
    HMODULE pinned;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN |
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, (LPCWSTR)(uintptr_t)&initialize, &pinned)) {
        FreeLibrary(backend);
        backend = NULL;
        return FALSE;
    }
    poll_mode();
    return TRUE;
}

static FARPROC entrypoint(const char *name) {
    if (!InitOnceExecuteOnce(&init_once, initialize, NULL, NULL)) return NULL;
    return GetProcAddress(backend, name);
}

/* Use local output slots even when the caller omits the device/context. This
 * installs the hooks before any returned swapchain or context reaches it. */
__declspec(dllexport) HRESULT WINAPI D3D11CreateDeviceAndSwapChain(
        IDXGIAdapter *adapter, D3D_DRIVER_TYPE driver, HMODULE software, UINT flags,
        const D3D_FEATURE_LEVEL *levels, UINT level_count, UINT sdk,
        const DXGI_SWAP_CHAIN_DESC *desc, IDXGISwapChain **swapchain,
        ID3D11Device **device, D3D_FEATURE_LEVEL *chosen, ID3D11DeviceContext **context) {
    typedef HRESULT (WINAPI *Create)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE,
        UINT, const D3D_FEATURE_LEVEL *, UINT, UINT, const DXGI_SWAP_CHAIN_DESC *,
        IDXGISwapChain **, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
    Create original = (Create)entrypoint("D3D11CreateDeviceAndSwapChain");
    if (!original) return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    if (!device && !context && !swapchain)
        return original(adapter, driver, software, flags, levels, level_count,
            sdk, desc, NULL, NULL, chosen, NULL);
    IDXGISwapChain *local_swapchain = NULL;
    ID3D11Device *local_device = NULL;
    ID3D11DeviceContext *local_context = NULL;
    HRESULT result = original(adapter, driver, software, flags, levels, level_count,
        sdk, desc, swapchain ? &local_swapchain : NULL, &local_device, chosen, &local_context);
    if (SUCCEEDED(result) && local_device) result = hook_device(local_device);
    if (FAILED(result)) {
        if (local_context) ID3D11DeviceContext_Release(local_context);
        if (local_device) ID3D11Device_Release(local_device);
        if (local_swapchain) IDXGISwapChain_Release(local_swapchain);
        if (swapchain) *swapchain = NULL;
        if (device) *device = NULL;
        if (context) *context = NULL;
        return result;
    }
    if (swapchain) *swapchain = local_swapchain;
    if (device) *device = local_device;
    else if (local_device) ID3D11Device_Release(local_device);
    if (context) *context = local_context;
    else if (local_context) ID3D11DeviceContext_Release(local_context);
    return result;
}

__declspec(dllexport) HRESULT WINAPI D3D11CreateDevice(
        IDXGIAdapter *adapter, D3D_DRIVER_TYPE driver, HMODULE software, UINT flags,
        const D3D_FEATURE_LEVEL *levels, UINT level_count, UINT sdk,
        ID3D11Device **device, D3D_FEATURE_LEVEL *chosen, ID3D11DeviceContext **context) {
    typedef HRESULT (WINAPI *Create)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE,
        UINT, const D3D_FEATURE_LEVEL *, UINT, UINT, ID3D11Device **,
        D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
    Create original = (Create)entrypoint("D3D11CreateDevice");
    if (!original) return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    if (!device && !context)
        return original(adapter, driver, software, flags, levels, level_count,
            sdk, NULL, chosen, NULL);
    ID3D11Device *local_device = NULL;
    ID3D11DeviceContext *local_context = NULL;
    HRESULT result = original(adapter, driver, software, flags, levels, level_count,
        sdk, &local_device, chosen, &local_context);
    if (SUCCEEDED(result) && local_device) result = hook_device(local_device);
    if (FAILED(result)) {
        if (local_context) ID3D11DeviceContext_Release(local_context);
        if (local_device) ID3D11Device_Release(local_device);
        if (device) *device = NULL;
        if (context) *context = NULL;
        return result;
    }
    if (device) *device = local_device;
    else if (local_device) ID3D11Device_Release(local_device);
    if (context) *context = local_context;
    else if (local_context) ID3D11DeviceContext_Release(local_context);
    return result;
}

__declspec(dllexport) HRESULT WINAPI D3D11CoreCreateDevice(IDXGIFactory *factory,
        IDXGIAdapter *adapter, UINT flags, const D3D_FEATURE_LEVEL *levels,
        UINT level_count, ID3D11Device **device) {
    typedef HRESULT (WINAPI *Create)(IDXGIFactory *, IDXGIAdapter *, UINT,
        const D3D_FEATURE_LEVEL *, UINT, ID3D11Device **);
    Create original = (Create)entrypoint("D3D11CoreCreateDevice");
    if (!original) return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    HRESULT result = original(factory, adapter, flags, levels, level_count, device);
    if (SUCCEEDED(result) && device && *device) {
        result = hook_device(*device);
        if (FAILED(result)) { ID3D11Device_Release(*device); *device = NULL; }
    }
    return result;
}

__declspec(dllexport) HRESULT WINAPI D3D11On12CreateDevice(IUnknown *device12,
        UINT flags, const D3D_FEATURE_LEVEL *levels, UINT level_count,
        IUnknown *const *queues, UINT queue_count, UINT node_mask,
        ID3D11Device **device, ID3D11DeviceContext **context, D3D_FEATURE_LEVEL *chosen) {
    typedef HRESULT (WINAPI *Create)(IUnknown *, UINT, const D3D_FEATURE_LEVEL *,
        UINT, IUnknown *const *, UINT, UINT, ID3D11Device **,
        ID3D11DeviceContext **, D3D_FEATURE_LEVEL *);
    Create original = (Create)entrypoint("D3D11On12CreateDevice");
    if (!original) return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    ID3D11Device *local_device = NULL;
    ID3D11DeviceContext *local_context = NULL;
    HRESULT result = original(device12, flags, levels, level_count, queues,
        queue_count, node_mask, device ? &local_device : NULL,
        context ? &local_context : NULL, chosen);
    if (SUCCEEDED(result) && !local_device && local_context)
        ID3D11DeviceContext_GetDevice(local_context, &local_device);
    if (SUCCEEDED(result) && local_device) result = hook_device(local_device);
    if (SUCCEEDED(result) && local_context) result = hook_context(local_context);
    if (FAILED(result)) {
        if (local_context) ID3D11DeviceContext_Release(local_context);
        if (local_device) ID3D11Device_Release(local_device);
        local_context = NULL;
        local_device = NULL;
    }
    if (device) *device = local_device;
    else if (local_device) ID3D11Device_Release(local_device);
    if (context) *context = local_context;
    return result;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        self_module = instance;
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}
