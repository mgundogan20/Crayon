using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using UnityEngine;

/// <summary>
/// Bit-exact C# model of the FPGA pipeline (intersect -> closest hit -> shade
/// -> hardware PerturbDirection), used to verify the FPGA's output.
///
/// Every operation goes through F.Mul/Add/Sub/Div with an explicit (float)
/// cast, because C# only guarantees single-precision rounding on an explicit
/// cast; this keeps the result identical to the IEEE single cores on any
/// runtime (Mono, IL2CPP, .NET). The order of operations is the same as in
/// Unity's Vector3.Dot/Cross and in FakePGA.CheckIntersection/Bounce.
///
/// Known, intentional difference from FakePGA.Bounce(): PerturbDirection uses
/// the hardware algorithm (xorshift32 + LUT + orthonormal basis) instead of
/// UnityEngine.Random + Quaternion.FromToRotation. Same distribution, but only
/// this version can be reproduced bit-for-bit.
/// Not modelled: the Xilinx cores flush denormals to zero (never seen with
/// normal scene scales).
/// </summary>
public static class FpgaReference
{
    // ---------------------------------------------------------------- float32 ops
    [StructLayout(LayoutKind.Explicit)]
    struct FU { [FieldOffset(0)] public float f; [FieldOffset(0)] public uint u; }

    public static uint Bits(float f) { FU x = new FU(); x.f = f; return x.u; }
    public static float FromBits(uint u) { FU x = new FU(); x.u = u; return x.f; }

    static class F
    {
        [MethodImpl(MethodImplOptions.NoInlining)] public static float Mul(float a, float b) { return (float)(a * b); }
        [MethodImpl(MethodImplOptions.NoInlining)] public static float Add(float a, float b) { return (float)(a + b); }
        [MethodImpl(MethodImplOptions.NoInlining)] public static float Sub(float a, float b) { return (float)(a - b); }
        [MethodImpl(MethodImplOptions.NoInlining)] public static float Div(float a, float b) { return (float)(a / b); }
        // double sqrt rounded once to float == correctly rounded float sqrt
        public static float Sqrt(float a) { return (float)Math.Sqrt((double)a); }
        public static float Neg(float a) { return FromBits(Bits(a) ^ 0x80000000u); }
    }

    struct V3
    {
        public float x, y, z;
        public V3(float x, float y, float z) { this.x = x; this.y = y; this.z = z; }
        public V3(Vector3 v) { x = v.x; y = v.y; z = v.z; }
        public Vector3 ToVector3() { return new Vector3(x, y, z); }
    }

    static V3 Cross(V3 a, V3 b)
    {
        return new V3(F.Sub(F.Mul(a.y, b.z), F.Mul(a.z, b.y)),
                      F.Sub(F.Mul(a.z, b.x), F.Mul(a.x, b.z)),
                      F.Sub(F.Mul(a.x, b.y), F.Mul(a.y, b.x)));
    }
    static float Dot(V3 a, V3 b)
    {
        return F.Add(F.Add(F.Mul(a.x, b.x), F.Mul(a.y, b.y)), F.Mul(a.z, b.z));
    }
    static V3 Sub(V3 a, V3 b) { return new V3(F.Sub(a.x, b.x), F.Sub(a.y, b.y), F.Sub(a.z, b.z)); }
    static V3 Add(V3 a, V3 b) { return new V3(F.Add(a.x, b.x), F.Add(a.y, b.y), F.Add(a.z, b.z)); }
    static V3 Mul(V3 a, V3 b) { return new V3(F.Mul(a.x, b.x), F.Mul(a.y, b.y), F.Mul(a.z, b.z)); }
    static V3 Scale(V3 a, float s) { return new V3(F.Mul(a.x, s), F.Mul(a.y, s), F.Mul(a.z, s)); }

    const float EPSILON = 1e-7f;

    // ---------------------------------------------------------------- intersect
    /// <summary>Same as FakePGA.CheckIntersection(...).distance; -1 on a miss.</summary>
    static float Intersect(V3 V0, V3 E1, V3 E2, V3 O, V3 D)
    {
        V3 P = Cross(D, E2);
        float det = Dot(E1, P);
        if (det > -EPSILON && det < EPSILON) return -1f;
        float invDet = F.Div(1.0f, det);
        V3 T = Sub(O, V0);
        float u = F.Mul(Dot(T, P), invDet);
        if (u < 0.0f || u > 1.0f) return -1f;
        V3 Q = Cross(T, E1);
        float v = F.Mul(Dot(D, Q), invDet);
        if (v < 0.0f || F.Add(u, v) > 1.0f) return -1f;
        return F.Mul(Dot(E2, Q), invDet);
    }

    // ---------------------------------------------------------------- RNG + perturb
    public static uint XorShift(uint s)
    {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s;
    }

    static readonly float K_WIDE = FromBits(0x3F6DE42Bu);   // 1 - cos(1.5f)     (after a bounce)
    static readonly float C_WIDE = FromBits(0xBF5BC856u);   // cos(1.5f) - K
    static readonly float K_NARROW = FromBits(0x35000000u);   // 1 - cos(0.001f)   (primary jitter)
    static readonly float C_NARROW = FromBits(0x3F7FFFF0u);   // cos(0.001f) - K

    /// <summary>Hardware PerturbDirection(n, maxAngle). n is assumed to be unit length.</summary>
    static V3 PerturbHW(V3 n, uint r1, uint r2, bool narrow)
    {
        float K_CT = narrow ? K_NARROW : K_WIDE, C_CT = narrow ? C_NARROW : C_WIDE;
        float f = FromBits(0x3F800000u | (r1 >> 9));                  // [1,2)
        float ct = F.Add(F.Mul(f, K_CT), C_CT);                       // cosTheta
        float st = F.Sqrt(F.Sub(1.0f, F.Mul(ct, ct)));                // sinTheta
        uint idx = r2 >> 22;
        float p = F.Mul(st, FromBits(FpgaPerturbLUT.CosBits[idx]));
        float q = F.Mul(st, FromBits(FpgaPerturbLUT.SinBits[idx]));

        // branch-free orthonormal basis (Duff et al. 2017)
        bool neg = (Bits(n.z) & 0x80000000u) != 0;
        float sg = neg ? -1.0f : 1.0f;
        float a = F.Div(-1.0f, F.Add(sg, n.z));
        float b = F.Mul(F.Mul(n.x, n.y), a);
        float xxa = F.Mul(F.Mul(n.x, n.x), a);
        float yya = F.Mul(F.Mul(n.y, n.y), a);
        V3 T = new V3(F.Add(1.0f, neg ? F.Neg(xxa) : xxa), neg ? F.Neg(b) : b, neg ? n.x : F.Neg(n.x));
        V3 B = new V3(b, F.Add(sg, yya), F.Neg(n.y));

        return new V3(F.Add(F.Add(F.Mul(T.x, p), F.Mul(n.x, ct)), F.Mul(B.x, q)),
                      F.Add(F.Add(F.Mul(T.y, p), F.Mul(n.y, ct)), F.Mul(B.y, q)),
                      F.Add(F.Add(F.Mul(T.z, p), F.Mul(n.z, ct)), F.Mul(B.z, q)));
    }

    // ---------------------------------------------------------------- scene
    struct Scene { public int nt; public V3[] v0, e1, e2, dif, em; }

    static Scene LoadScene(List<Polygon> tris)
    {
        Scene sc = new Scene();
        sc.nt = tris.Count;
        sc.v0 = new V3[sc.nt]; sc.e1 = new V3[sc.nt]; sc.e2 = new V3[sc.nt]; sc.dif = new V3[sc.nt]; sc.em = new V3[sc.nt];
        for (int k = 0; k < sc.nt; k++)
        {
            sc.v0[k] = new V3(tris[k].V0); sc.e1[k] = new V3(tris[k].E1); sc.e2[k] = new V3(tris[k].E2);
            sc.dif[k] = new V3(tris[k].diffuseColor); sc.em[k] = new V3(tris[k].emissionColor);
        }
        return sc;
    }

    /// <summary>All bounces for one batch of rays (what the FPGA does between GEN and SEND).</summary>
    static void TraceBatch(Scene sc, V3[] O, V3[] D, V3[] RC, V3[] AC, int n, int bounces, bool perturb, ref uint state)
    {
        V3 sky = new V3(0.2f, 0.2f, 0.2f);
        for (int bnc = 0; bnc < bounces; bnc++)
        {
            for (int r = 0; r < n; r++)
            {
                float best = 1e10f; int bi = 0;
                for (int k = 0; k < sc.nt; k++)
                {
                    float d = Intersect(sc.v0[k], sc.e1[k], sc.e2[k], O[r], D[r]);
                    if (d > EPSILON && d < best) { best = d; bi = k; }
                }

                uint r1 = XorShift(state), r2 = XorShift(r1);    // drawn for every ray
                state = r2;

                if (best < 1e9f)
                {
                    AC[r] = Add(AC[r], Mul(RC[r], sc.em[bi]));
                    RC[r] = Mul(RC[r], sc.dif[bi]);
                    V3 dir = D[r];
                    O[r] = Add(O[r], Scale(dir, best));
                    V3 nrm = Cross(sc.e1[bi], sc.e2[bi]);
                    float mag = F.Sqrt(Dot(nrm, nrm));
                    nrm = new V3(F.Div(nrm.x, mag), F.Div(nrm.y, mag), F.Div(nrm.z, mag));
                    float dd = Dot(dir, nrm);
                    V3 refl = Scale(new V3(F.Mul(nrm.x, 2f), F.Mul(nrm.y, 2f), F.Mul(nrm.z, 2f)), dd);
                    dir = Sub(dir, refl);
                    if (perturb) dir = PerturbHW(dir, r1, r2, false);
                    D[r] = dir;
                }
                else
                {
                    AC[r] = Add(AC[r], Mul(RC[r], sky));
                    RC[r] = new V3(0f, 0f, 0f);
                }
            }
        }
    }

    // ---------------------------------------------------------------- ray-packet frame
    /// <summary>
    /// Frame with rays sent from the PC (ray packet): 'bounces' bounces over 'rays'
    /// in the order sent. ray_col / accum_col are reset to 1 / 0 like on the FPGA.
    /// </summary>
    public static void TraceFrame(List<Polygon> tris, RTRay[] rays, int bounces, bool perturb, uint seed)
    {
        Scene sc = LoadScene(tris);
        int n = rays.Length;
        V3[] O = new V3[n], D = new V3[n], RC = new V3[n], AC = new V3[n];
        for (int r = 0; r < n; r++)
        {
            O[r] = new V3(rays[r].origin); D[r] = new V3(rays[r].direction);
            RC[r] = new V3(1f, 1f, 1f); AC[r] = new V3(0f, 0f, 0f);
        }
        uint state = seed == 0 ? 1u : seed;
        TraceBatch(sc, O, D, RC, AC, n, bounces, perturb, ref state);
        for (int r = 0; r < n; r++)
        {
            rays[r].origin = O[r].ToVector3(); rays[r].direction = D[r].ToVector3();
            rays[r].ray_col = RC[r].ToVector3(); rays[r].accum_col = AC[r].ToVector3();
        }
    }

    // ---------------------------------------------------------------- camera frame
    public struct CameraSetup
    {
        public Vector3 position, forward, right, up;
        public float fov;
        public int xRes, yRes;
    }

    /// <summary>
    /// Frame with rays generated on the FPGA (camera packet). Primary directions are
    /// computed exactly like FakePGA.GeneratePrimaries():
    ///   d = ((x - X/2)*fov * right + (y - Y/2)*fov * up) + forward
    /// then normalized, then jittered with the hardware PerturbDirection(d, 0.001f).
    /// Pixels are processed x-major in batches of 'batchSize' (= FPGA MAX_RAYS).
    /// Returns accum_col per pixel, index x*yRes + y. Only the first 'maxBatches'
    /// batches are computed (the rest of the array stays zero) -- the RNG stream is
    /// independent of the results, so a partial check is still exact.
    /// </summary>
    public static Vector3[] TraceCameraFrame(List<Polygon> tris, CameraSetup cam, int bounces, bool perturb,
                                             bool jitter, uint seed, int batchSize, int maxBatches = int.MaxValue)
    {
        Scene sc = LoadScene(tris);
        int total = cam.xRes * cam.yRes;
        Vector3[] result = new Vector3[total];
        V3 right = new V3(cam.right), up = new V3(cam.up), fwd = new V3(cam.forward), pos = new V3(cam.position);

        V3[] O = new V3[batchSize], D = new V3[batchSize], RC = new V3[batchSize], AC = new V3[batchSize];
        uint state = seed == 0 ? 1u : seed;
        int batch = 0;
        for (int start = 0; start < total && batch < maxBatches; start += batchSize, batch++)
        {
            int n = Math.Min(batchSize, total - start);
            for (int r = 0; r < n; r++)
            {
                int g = start + r, x = g / cam.yRes, y = g % cam.yRes;
                float dx = F.Mul((float)(x - cam.xRes / 2), cam.fov);
                float dy = F.Mul((float)(y - cam.yRes / 2), cam.fov);
                V3 d = Add(Add(Scale(right, dx), Scale(up, dy)), fwd);
                float mag = F.Sqrt(Dot(d, d));
                d = new V3(F.Div(d.x, mag), F.Div(d.y, mag), F.Div(d.z, mag));

                uint r1 = XorShift(state), r2 = XorShift(r1);
                state = r2;
                if (jitter) d = PerturbHW(d, r1, r2, true);

                O[r] = pos; D[r] = d; RC[r] = new V3(1f, 1f, 1f); AC[r] = new V3(0f, 0f, 0f);
            }
            TraceBatch(sc, O, D, RC, AC, n, bounces, perturb, ref state);
            for (int r = 0; r < n; r++) result[start + r] = AC[r].ToVector3();
        }
        return result;
    }
}