#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <d3d11_3.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while(0)
#define HR(x) do { HRESULT hr_=(x); if(FAILED(hr_)) { fprintf(stderr,"FAIL line %d: %s = %08lx\n",__LINE__,#x,(unsigned long)hr_); exit(1); } } while(0)
typedef HRESULT (WINAPI *Create)(IDXGIAdapter *,D3D_DRIVER_TYPE,HMODULE,UINT,const D3D_FEATURE_LEVEL *,UINT,UINT,ID3D11Device **,D3D_FEATURE_LEVEL *,ID3D11DeviceContext **);
static void select_mode(int mode) {
    FILE *file=fopen("gow_proxy_depth.txt","wb"); CHECK(file);
    CHECK(fprintf(file,"%d\n",mode)==2); CHECK(fclose(file)==0); Sleep(300);
}
static void verify_bound(ID3D11DeviceContext *context, D3D11_COMPARISON_FUNC comparison,
        const D3D11_DEPTH_STENCIL_DESC *wanted, UINT expected_ref) {
    ID3D11DepthStencilState *bound=NULL; UINT ref=0;
    ID3D11DeviceContext_OMGetDepthStencilState(context,&bound,&ref);
    CHECK(bound && ref==expected_ref);
    D3D11_DEPTH_STENCIL_DESC actual; ID3D11DepthStencilState_GetDesc(bound,&actual);
    CHECK(actual.DepthFunc==comparison && actual.DepthEnable==wanted->DepthEnable);
    CHECK(actual.DepthWriteMask==wanted->DepthWriteMask && actual.StencilEnable==wanted->StencilEnable);
    CHECK(actual.StencilReadMask==wanted->StencilReadMask && actual.StencilWriteMask==wanted->StencilWriteMask);
    const D3D11_DEPTH_STENCILOP_DESC *a[]={&actual.FrontFace,&actual.BackFace};
    const D3D11_DEPTH_STENCILOP_DESC *b[]={&wanted->FrontFace,&wanted->BackFace};
    for(unsigned i=0;i<2;i++) {
        CHECK(a[i]->StencilFailOp==b[i]->StencilFailOp && a[i]->StencilDepthFailOp==b[i]->StencilDepthFailOp);
        CHECK(a[i]->StencilPassOp==b[i]->StencilPassOp && a[i]->StencilFunc==b[i]->StencilFunc);
    }
    ID3D11DepthStencilState_Release(bound);
}
int main(void) {
    HMODULE proxy=LoadLibraryW(L"d3d11.dll"); CHECK(proxy);
    WCHAR system_path[32768]; UINT length=GetSystemDirectoryW(system_path,32768);
    CHECK(length && length+11<32768); wcscat(system_path,L"\\d3d11.dll");
    HMODULE native=LoadLibraryExW(system_path,NULL,LOAD_WITH_ALTERED_SEARCH_PATH);
    CHECK(native && native!=proxy);
    Create create_native=(Create)GetProcAddress(native,"D3D11CreateDevice"); CHECK(create_native);
    Create create_proxy=(Create)GetProcAddress(proxy,"D3D11CreateDevice"); CHECK(create_proxy);
    ID3D11Device *device=NULL; ID3D11DeviceContext *context=NULL;
    D3D11_DEPTH_STENCIL_DESC desc={0};
    desc.DepthEnable=TRUE; desc.DepthWriteMask=D3D11_DEPTH_WRITE_MASK_ZERO;
    desc.DepthFunc=D3D11_COMPARISON_EQUAL; desc.StencilEnable=TRUE;
    desc.StencilReadMask=0x5a; desc.StencilWriteMask=0x7c;
    desc.FrontFace.StencilFailOp=D3D11_STENCIL_OP_KEEP;
    desc.FrontFace.StencilDepthFailOp=D3D11_STENCIL_OP_REPLACE;
    desc.FrontFace.StencilPassOp=D3D11_STENCIL_OP_INCR;
    desc.FrontFace.StencilFunc=D3D11_COMPARISON_ALWAYS;
    desc.BackFace=desc.FrontFace;
    HR(create_native(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,NULL,0,D3D11_SDK_VERSION,&device,NULL,&context));
    ID3D11DepthStencilState *state=NULL;
    HR(ID3D11Device_CreateDepthStencilState(device,&desc,&state));
    ID3D11DeviceContext_OMSetDepthStencilState(context,state,17);
    verify_bound(context,D3D11_COMPARISON_EQUAL,&desc,17);
    ID3D11DepthStencilState_Release(state); ID3D11DeviceContext_ClearState(context);
    ID3D11DeviceContext_Release(context); ID3D11Device_Release(device);
    puts("PASS selected native backend binds EQUAL before interception");
    select_mode(2);
    HR(create_proxy(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,NULL,0,D3D11_SDK_VERSION,&device,NULL,&context));
    HR(ID3D11Device_CreateDepthStencilState(device,&desc,&state));
    ID3D11DeviceContext_OMSetDepthStencilState(context,state,23);
    verify_bound(context,D3D11_COMPARISON_GREATER_EQUAL,&desc,23);
    D3D11_DEPTH_STENCIL_DESC original; ID3D11DepthStencilState_GetDesc(state,&original);
    CHECK(original.DepthFunc==D3D11_COMPARISON_EQUAL);
    puts("PASS proxy substitutes GREATER_EQUAL and preserves stencil configuration");
    select_mode(0);
    ID3D11DeviceContext_OMSetDepthStencilState(context,state,24);
    verify_bound(context,D3D11_COMPARISON_EQUAL,&desc,24);
    select_mode(2);
    ID3D11DeviceContext_OMSetDepthStencilState(context,state,25);
    verify_bound(context,D3D11_COMPARISON_GREATER_EQUAL,&desc,25);
    ID3D11DepthStencilState_Release(state);
    verify_bound(context,D3D11_COMPARISON_GREATER_EQUAL,&desc,25);
    puts("PASS live 2 -> 0 -> 2 toggle and bound-state lifetime");
    desc.DepthFunc=D3D11_COMPARISON_LESS_EQUAL;
    HR(ID3D11Device_CreateDepthStencilState(device,&desc,&state));
    ID3D11DeviceContext_OMSetDepthStencilState(context,state,26);
    verify_bound(context,D3D11_COMPARISON_LESS_EQUAL,&desc,26);
    ID3D11DepthStencilState_Release(state);
    ID3D11DeviceContext_ClearState(context);
    ID3D11DeviceContext_Release(context); ID3D11Device_Release(device);
    puts("PASS non-EQUAL state remains unchanged");
    return 0;
}
