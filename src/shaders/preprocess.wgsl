const SH_C0: f32 = 0.28209479177387814;
const SH_C1 = 0.4886025119029199;
const SH_C2 = array<f32,5>(
    1.0925484305920792,
    -1.0925484305920792,
    0.31539156525252005,
    -1.0925484305920792,
    0.5462742152960396
);
const SH_C3 = array<f32,7>(
    -0.5900435899266435,
    2.890611442640554,
    -0.4570457994644658,
    0.3731763325901154,
    -0.4570457994644658,
    1.445305721320277,
    -0.5900435899266435
);

override workgroupSize: u32;
override sortKeyPerThread: u32;

struct DispatchIndirect {
    dispatch_x: atomic<u32>,
    dispatch_y: u32,
    dispatch_z: u32,
};

struct SortInfos {
    keys_size: atomic<u32>,  // instance_count in DrawIndirect
    //data below is for info inside radix sort 
    padded_size: u32, 
    passes: u32,
    even_pass: u32,
    odd_pass: u32,
};

struct CameraUniforms {
    view: mat4x4<f32>,
    view_inv: mat4x4<f32>,
    proj: mat4x4<f32>,
    proj_inv: mat4x4<f32>,
    viewport: vec2<f32>,
    focal: vec2<f32>
};

struct RenderSettings {
    gaussian_scaling: f32,
    sh_deg: f32,
};

struct Gaussian {
    pos_opacity: array<u32,2>,
    rot: array<u32,2>,
    scale: array<u32,2>
};

struct Splat {
    packed_pos: u32,
    packed_size: u32,
    packed_color: array<u32, 2>,
    packed_conic_opacity: array<u32, 2>,
};

//TODO: bind your data here
@group(0) @binding(0)
var<uniform> camera: CameraUniforms;
@group(0) @binding(1)
var<uniform> render_settings: RenderSettings;

@group(1) @binding(0)
var<storage, read> gaussians: array<Gaussian>;
@group(1) @binding(1)
var<storage, read_write> splats: array<Splat>;
@group(1) @binding(2)
var<storage, read> colors: array<u32>;

@group(2) @binding(0)
var<storage, read_write> sort_infos: SortInfos;
@group(2) @binding(1)
var<storage, read_write> sort_depths : array<u32>;
@group(2) @binding(2)
var<storage, read_write> sort_indices : array<u32>;
@group(2) @binding(3)
var<storage, read_write> sort_dispatch: DispatchIndirect;

/// reads the ith sh coef from the storage buffer 
fn sh_coef(splat_idx: u32, c_idx: u32) -> vec3<f32> {
    //TODO: access your binded sh_coeff, see load.ts for how it is stored
    let index = splat_idx * 24 + c_idx % 2 + c_idx / 2 * 3;
    let color_a_b = unpack2x16float(colors[index]);
    let color_c_d = unpack2x16float(colors[index + 1]);

    if (c_idx % 2 == 0) {
        return vec3f(color_a_b.x, color_a_b.y, color_c_d.x);
    } else {
        return vec3f(color_a_b.y, color_c_d.x, color_c_d.y);
    }
}

// spherical harmonics evaluation with Condon–Shortley phase
fn computeColorFromSH(dir: vec3<f32>, v_idx: u32, sh_deg: u32) -> vec3<f32> {
    var result = SH_C0 * sh_coef(v_idx, 0u);

    if sh_deg > 0u {

        let x = dir.x;
        let y = dir.y;
        let z = dir.z;

        result += - SH_C1 * y * sh_coef(v_idx, 1u) + SH_C1 * z * sh_coef(v_idx, 2u) - SH_C1 * x * sh_coef(v_idx, 3u);

        if sh_deg > 1u {

            let xx = dir.x * dir.x;
            let yy = dir.y * dir.y;
            let zz = dir.z * dir.z;
            let xy = dir.x * dir.y;
            let yz = dir.y * dir.z;
            let xz = dir.x * dir.z;

            result += SH_C2[0] * xy * sh_coef(v_idx, 4u) + SH_C2[1] * yz * sh_coef(v_idx, 5u) + SH_C2[2] * (2.0 * zz - xx - yy) * sh_coef(v_idx, 6u) + SH_C2[3] * xz * sh_coef(v_idx, 7u) + SH_C2[4] * (xx - yy) * sh_coef(v_idx, 8u);

            if sh_deg > 2u {
                result += SH_C3[0] * y * (3.0 * xx - yy) * sh_coef(v_idx, 9u) + SH_C3[1] * xy * z * sh_coef(v_idx, 10u) + SH_C3[2] * y * (4.0 * zz - xx - yy) * sh_coef(v_idx, 11u) + SH_C3[3] * z * (2.0 * zz - 3.0 * xx - 3.0 * yy) * sh_coef(v_idx, 12u) + SH_C3[4] * x * (4.0 * zz - xx - yy) * sh_coef(v_idx, 13u) + SH_C3[5] * z * (xx - yy) * sh_coef(v_idx, 14u) + SH_C3[6] * x * (xx - 3.0 * yy) * sh_coef(v_idx, 15u);
            }
        }
    }
    result += 0.5;

    return  max(vec3<f32>(0.), result);
}

@compute @workgroup_size(workgroupSize,1,1)
fn preprocess(@builtin(global_invocation_id) gid: vec3<u32>, @builtin(num_workgroups) wgs: vec3<u32>) {
    let idx = gid.x;
    if (idx >= arrayLength(&gaussians)) {
        return;
    }

    // extract gaussian information
    let gaussian = gaussians[idx];
    let pos_xy = unpack2x16float(gaussian.pos_opacity[0]);
    let pos_za = unpack2x16float(gaussian.pos_opacity[1]);
    let pos = vec4f(pos_xy, pos_za.x, 1.0);
    let opacity = 1.0f / (1.0f + exp(-pos_za.y));

    // get ndc
    let view_pos = camera.view * pos;
    var ndc = camera.proj * view_pos;
    ndc /= ndc.w;

    // view-frustum culling
    if (ndc.x < -1.2 || ndc.x > 1.2 ||
        ndc.y < -1.2 || ndc.y > 1.2 ||
        view_pos.z <= 0.0) {
        return;
    }

    // get rotation
    let rot_wx = unpack2x16float(gaussian.rot[0]);
    let rot_yz = unpack2x16float(gaussian.rot[1]);
    let w = rot_wx.x;
    let x = rot_wx.y;
    let y = rot_yz.x;
    let z = rot_yz.y;

    let R = mat3x3f(
        1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - w * z)      , 2.0 * (x * z + w * y),
        2.0 * (x * y + w * z)      , 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - w * x),
        2.0 * (x * z - w * y)      , 2.0 * (y * z + w * x)      , 1.0 - 2.0 * (x * x + y * y)
    );

    // get scale
    let scale_xy = exp(unpack2x16float(gaussian.scale[0]));
    let scale_zw = exp(unpack2x16float(gaussian.scale[1]));
    let sx = scale_xy.x * render_settings.gaussian_scaling;
    let sy = scale_xy.y * render_settings.gaussian_scaling;
    let sz = scale_zw.x * render_settings.gaussian_scaling;
    let S = mat3x3f(
        sx, 0.0, 0.0,
        0.0, sy, 0.0,
        0.0, 0.0, sz
    );

    let Cov3D = transpose(R) * transpose(S) * S * R;

    // Jacobian
    let J = mat3x3f(
        camera.focal.x / view_pos.z, 0.0, -camera.focal.x * view_pos.x / (view_pos.z * view_pos.z),
        0.0, camera.focal.y / view_pos.z, -camera.focal.y * view_pos.y / (view_pos.z * view_pos.z),
        0.0, 0.0, 0.0
    );

    let W = transpose(mat3x3f(
        camera.view[0].xyz, camera.view[1].xyz, camera.view[2].xyz
    ));

    let WJ = W * J;

    let Sigma = mat3x3f(
        Cov3D[0][0], Cov3D[0][1], Cov3D[0][2],
        Cov3D[0][1], Cov3D[1][1], Cov3D[1][2],
        Cov3D[0][2], Cov3D[1][2], Cov3D[2][2]
    );

    var Cov2D = transpose(WJ) * Sigma * WJ;
    Cov2D[0][0] += 0.3;
    Cov2D[1][1] += 0.3;
    let cxx = Cov2D[0][0];
    let cyy = Cov2D[1][1];
    let cxy = Cov2D[0][1];

    let det = cxx * cyy - cxy * cxy;
    if (det == 0.0) { return; }

    let mid = (cxx + cyy) * 0.5;
    let lambda1 = mid + sqrt(max(0.1, mid * mid - det));
    let lambda2 = mid - sqrt(max(0.1, mid * mid - det));
    let radius = ceil(3.0f * sqrt(max(lambda1, lambda2)));

    let cam_pos = -camera.view[3].xyz;
    let direction = normalize(pos.xyz- cam_pos);
    let color = computeColorFromSH(direction, idx, u32(render_settings.sh_deg));

    let conic = vec3f(cyy / det, -cxy / det, cxx / det);

    let sorted_idx = atomicAdd(&sort_infos.keys_size, 1);
    splats[sorted_idx].packed_pos = pack2x16float(ndc.xy);
    splats[sorted_idx].packed_size = pack2x16float(vec2f(radius, radius) / camera.viewport);
    splats[sorted_idx].packed_color[0] = pack2x16float(color.rg);
    splats[sorted_idx].packed_color[1] = pack2x16float(vec2f(color.b, 1.0f));
    splats[sorted_idx].packed_conic_opacity[0] = pack2x16float(conic.xy); 
    splats[sorted_idx].packed_conic_opacity[1] = pack2x16float(vec2f(conic.z, opacity));

    sort_depths[sorted_idx] = bitcast<u32>(100.0 - view_pos.z);
    sort_indices[sorted_idx] = sorted_idx;

    let keys_per_dispatch = workgroupSize * sortKeyPerThread; 
    // increment DispatchIndirect.dispatchx each time you reach limit for one dispatch of keys
    if (sorted_idx % keys_per_dispatch == 0) {
        atomicAdd(&sort_dispatch.dispatch_x, 1);
    }
}