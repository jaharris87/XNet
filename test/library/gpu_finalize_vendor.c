/* Host-only bookkeeping model, not a simulation of GPU fault recovery.
 * Failed destruction leaves the resource live. A stream must outlive every
 * handle bound to it, and a successful destructor must never be repeated.
 */
#include <stdio.h>
#include <string.h>

enum { STREAM = 1, BLAS = 2, SOLVER = 3, BORROWED_SOLVER = 4, KINDS = 5 };
enum { INVALID_RESOURCE = 91, RESOURCE_LIMIT = 64 };
struct resource {
    int kind, live, borrowed;
    void *stream;
};
static struct resource resources[RESOURCE_LIMIT];
static int used, invalid_calls, sync_calls;
static int creates[KINDS], destroys[KINDS], failures[KINDS];

static int invalid(const char *operation)
{
    ++invalid_calls;
    fprintf(stderr, "invalid simulated vendor call: %s\n", operation);
    return INVALID_RESOURCE;
}

static struct resource *find(void *pointer, int kind)
{
    int i;
    for (i = 0; i < used; ++i) {
        if (pointer == &resources[i] &&
            (resources[i].kind == kind ||
             (kind == SOLVER && resources[i].kind == BORROWED_SOLVER)))
            return &resources[i];
    }
    return NULL;
}

static void *allocate(int kind, int borrowed, void *stream)
{
    struct resource *r;
    if (used == RESOURCE_LIMIT) {
        invalid("resource pool exhausted");
        return NULL;
    }
    r = &resources[used++];
    r->kind = kind;
    r->live = 1;
    r->borrowed = borrowed;
    r->stream = stream;
    return r;
}

static int create(void **pointer, int kind)
{
    ++creates[kind];
    *pointer = allocate(kind, 0, NULL);
    return *pointer ? 0 : INVALID_RESOURCE;
}

static int destroy(void *pointer, int kind)
{
    struct resource *r = find(pointer, kind);
    int i;
    ++destroys[kind];
    if (!r || !r->live) return invalid("destroy invalid or dead resource");
    if (r->borrowed) return invalid("destroy caller-owned resource");
    if (kind == STREAM) {
        for (i = 0; i < used; ++i)
            if (resources[i].live && resources[i].stream == pointer)
                return invalid("destroy stream before a dependent handle");
    } else if (!find(r->stream, STREAM) || !find(r->stream, STREAM)->live) {
        return invalid("destroy handle after its stream");
    }
    if (failures[kind] > 0) {
        --failures[kind];
        return 70 + kind;
    }
    r->live = 0;
    return 0;
}

static int get_stream(void *pointer, void **stream, int kind)
{
    struct resource *r = find(pointer, kind);
    if (!r || !r->live) return invalid("query invalid or dead handle");
    *stream = r->stream;
    return 0;
}

static int set_stream(void *pointer, void *stream, int kind)
{
    struct resource *r = find(pointer, kind), *s = find(stream, STREAM);
    if (!r || !r->live || !s || !s->live)
        return invalid("bind invalid handle or stream");
    r->stream = stream;
    return 0;
}

static int synchronize(void *pointer)
{
    struct resource *r = find(pointer, STREAM);
    ++sync_calls;
    return r && r->live ? 0 : invalid("synchronize invalid or dead stream");
}

int vendor_live(int kind)
{
    int i, n = 0;
    for (i = 0; i < used; ++i)
        if (resources[i].live && resources[i].kind == kind) ++n;
    return n;
}
int vendor_creates(int kind) { return creates[kind]; }
int vendor_destroys(int kind) { return destroys[kind]; }
int vendor_invalid(void) { return invalid_calls; }
int vendor_syncs(void) { return sync_calls; }
void vendor_fail(int kind, int count) { failures[kind] = count; }

int vendor_reset(void)
{
    int i;
    for (i = 0; i < used; ++i)
        if (resources[i].live) return invalid("reset with live resources");
    memset(resources, 0, sizeof resources);
    memset(creates, 0, sizeof creates);
    memset(destroys, 0, sizeof destroys);
    memset(failures, 0, sizeof failures);
    used = invalid_calls = sync_calls = 0;
    return 0;
}

void *vendor_borrow(int kind, void *stream)
{
    struct resource *s = find(stream, STREAM);
    if (kind < STREAM || kind >= KINDS ||
        (kind != STREAM && (!s || !s->live))) {
        invalid("create caller resource with invalid stream");
        return NULL;
    }
    return allocate(kind, 1, stream);
}

void vendor_release_borrowed(void)
{
    int i;
    /* The caller releases its handles before its streams. This is separate
     * from vendor destruction counters, which record only XNet's calls. */
    for (i = 0; i < used; ++i)
        if (resources[i].borrowed && resources[i].kind != STREAM) resources[i].live = 0;
    for (i = 0; i < used; ++i)
        if (resources[i].borrowed) resources[i].live = 0;
}

int cudaGetDeviceCount(int *n) { *n = 1; return 0; }
int cudaGetDevice(int *d) { *d = 0; return 0; }
int cudaSetDevice(int d) { return d == 0 ? 0 : invalid("select device"); }
int cudaStreamCreate(void **s) { return create(s, STREAM); }
int cudaStreamDestroy(void *s) { return destroy(s, STREAM); }
int cudaStreamSynchronize(void *s) { return synchronize(s); }
int cudaDeviceSynchronize(void) { return 0; }
int cublasCreate_v2(void **h) { return create(h, BLAS); }
int cublasDestroy_v2(void *h) { return destroy(h, BLAS); }
int cublasGetStream_v2(void *h, void **s) { return get_stream(h, s, BLAS); }
int cublasSetStream_v2(void *h, void *s) { return set_stream(h, s, BLAS); }
int cublasSetSmCountTarget(void *h, int n)
{
    struct resource *r = find(h, BLAS);
    return r && r->live && n >= 0 ? 0 : invalid("set SM count");
}
int cusolverDnCreate(void **h) { return create(h, SOLVER); }
int cusolverDnDestroy(void *h) { return destroy(h, SOLVER); }
int cusolverDnGetStream(void *h, void **s) { return get_stream(h, s, SOLVER); }
int cusolverDnSetStream(void *h, void *s) { return set_stream(h, s, SOLVER); }

int hipGetDeviceCount(int *n) { return cudaGetDeviceCount(n); }
int hipGetDevice(int *d) { return cudaGetDevice(d); }
int hipSetDevice(int d) { return cudaSetDevice(d); }
int hipStreamCreate(void **s) { return create(s, STREAM); }
int hipStreamDestroy(void *s) { return destroy(s, STREAM); }
int hipStreamSynchronize(void *s) { return synchronize(s); }
int hipDeviceSynchronize(void) { return 0; }
int hipblasCreate(void **h) { return create(h, BLAS); }
int hipblasDestroy(void *h) { return destroy(h, BLAS); }
int hipblasGetStream(void *h, void **s) { return get_stream(h, s, BLAS); }
int hipblasSetStream(void *h, void *s) { return set_stream(h, s, BLAS); }
int rocblas_create_handle(void **h) { return create(h, SOLVER); }
int rocblas_destroy_handle(void *h) { return destroy(h, SOLVER); }
int rocblas_get_stream(void *h, void **s) { return get_stream(h, s, SOLVER); }
int rocblas_set_stream(void *h, void *s) { return set_stream(h, s, SOLVER); }
int rocblas_set_pointer_mode(void *h, int mode)
{
    struct resource *r = find(h, SOLVER);
    return r && r->live && mode >= 0 ? 0 : invalid("set pointer mode");
}
