#include <assert.h>
#include <math.h>
#include <stdio.h>

#include "../visible_rect.h"

static void expect_close(float actual, float expected) {
    const float eps = 1e-6f;
    if (fabsf(actual - expected) > eps) {
        fprintf(stderr, "expected %.8f, got %.8f\n", expected, actual);
        assert(0);
    }
}

int main(void) {
    svi_visible_rect r;

    r = svi_compute_visible_rect(1280, 720, 1280, 720, 0, 0, 0, 0);
    expect_close(r.u0, 0.0f);
    expect_close(r.v0, 0.0f);
    expect_close(r.u1, 1.0f);
    expect_close(r.v1, 1.0f);
    assert(r.visible_w == 1280);
    assert(r.visible_h == 720);
    assert(r.clipped == 0);

    r = svi_compute_visible_rect(1920, 1088, 1920, 1080, 0, 0, 0, 0);
    expect_close(r.u0, 0.0f);
    expect_close(r.v0, 0.0f);
    expect_close(r.u1, 1.0f);
    expect_close(r.v1, 1080.0f / 1088.0f);
    assert(r.visible_w == 1920);
    assert(r.visible_h == 1080);
    assert(r.clipped == 1);

    r = svi_compute_visible_rect(1920, 1088, 1920, 1088, 0, 0, 0, 8);
    expect_close(r.v0, 0.0f);
    expect_close(r.v1, 1080.0f / 1088.0f);
    assert(r.visible_h == 1080);

    r = svi_compute_visible_rect(1920, 1088, 1920, 1088, 0, 0, 8, 0);
    expect_close(r.v0, 8.0f / 1088.0f);
    expect_close(r.v1, 1.0f);
    assert(r.visible_h == 1080);

    r = svi_compute_visible_rect(1920, 1088, 1920, 1088, 5000, 0, 0, 0);
    expect_close(r.u0, 1919.0f / 1920.0f);
    expect_close(r.u1, 1.0f);
    assert(r.visible_w == 1);

    printf("visible_rect tests passed\n");
    return 0;
}
