using System;
using System.Collections.Generic;
using UnityEngine;

public struct RayTraceTriangle
{
    public Vector3 v0;
    public Vector3 e1;
    public Vector3 e2;
    public Vector3 diffuseColor;
    public Vector3 emissionColor;
}

public struct RayTraceRay
{
    public Vector3 origin;
    public Vector3 direction;
}

public struct RayTraceHit
{
    public bool hit;
    public int triangleIndex;
    public int distanceQ16;

    public float Distance
    {
        get { return distanceQ16 / 65536.0f; }
    }
}

public static class RayTraceBatch
{
    public const int MaxTriangles = 256;
    public const int MaxRays = 256;
    public const float FixedPointScale = 65536.0f;

    public static RayTraceHit[] TraceCpuReference(
        IReadOnlyList<RayTraceTriangle> triangles,
        IReadOnlyList<RayTraceRay> rays)
    {
        if (triangles == null)
            throw new ArgumentNullException(nameof(triangles));
        if (rays == null)
            throw new ArgumentNullException(nameof(rays));
        if (triangles.Count > MaxTriangles)
            throw new ArgumentOutOfRangeException(nameof(triangles), "The current FPGA scene limit is 256 triangles.");

        RayTraceHit[] results = new RayTraceHit[rays.Count];
        for (int rayIndex = 0; rayIndex < rays.Count; rayIndex++)
        {
            int bestDistance = int.MaxValue;
            int bestTriangle = -1;

            for (int triangleIndex = 0; triangleIndex < triangles.Count; triangleIndex++)
            {
                RayTraceTriangle triangle = triangles[triangleIndex];
                if (TryIntersectQ16(
                    rays[rayIndex],
                    triangle,
                    out int distanceQ16) &&
                    distanceQ16 < bestDistance)
                {
                    bestDistance = distanceQ16;
                    bestTriangle = triangleIndex;
                }
            }

            results[rayIndex] = new RayTraceHit
            {
                hit = bestTriangle >= 0,
                triangleIndex = bestTriangle,
                distanceQ16 = bestTriangle >= 0 ? bestDistance : 0
            };
        }

        return results;
    }

    public static bool TryIntersectQ16(
        RayTraceRay ray,
        RayTraceTriangle triangle,
        out int distanceQ16)
    {
        int[] origin = ToFixedVector(ray.origin);
        int[] direction = ToFixedVector(ray.direction);
        int[] v0 = ToFixedVector(triangle.v0);
        int[] e1 = ToFixedVector(triangle.e1);
        int[] e2 = ToFixedVector(triangle.e2);

        int[] p = Cross(direction, e2);
        int determinant = Dot(e1, p);
        if (determinant == 0)
        {
            distanceQ16 = 0;
            return false;
        }

        int[] t = Subtract(origin, v0);
        int uNumerator = Dot(t, p);
        int[] q = Cross(t, e1);
        int vNumerator = Dot(direction, q);
        int tNumerator = Dot(e2, q);

        long u = uNumerator;
        long v = vNumerator;
        long det = determinant;
        if (det > 0)
        {
            if (u < 0 || u > det || v < 0 || u + v > det)
            {
                distanceQ16 = 0;
                return false;
            }
        }
        else if (u > 0 || u < det || v > 0 || u + v < det)
        {
            distanceQ16 = 0;
            return false;
        }

        long scaledNumerator = (long)tNumerator << 16;
        long distance = scaledNumerator / determinant;
        if (distance <= 0 || distance > int.MaxValue)
        {
            distanceQ16 = 0;
            return false;
        }

        distanceQ16 = (int)distance;
        return true;
    }

    private static int[] ToFixedVector(Vector3 value)
    {
        return new[]
        {
            ToFixed(value.x),
            ToFixed(value.y),
            ToFixed(value.z)
        };
    }

    private static int ToFixed(float value)
    {
        if (float.IsNaN(value) || float.IsInfinity(value))
            throw new ArgumentOutOfRangeException(nameof(value), "Ray and scene coordinates must be finite.");

        double scaled = Math.Round(value * (double)FixedPointScale, MidpointRounding.AwayFromZero);
        if (scaled > int.MaxValue || scaled < int.MinValue)
            throw new ArgumentOutOfRangeException(nameof(value), "A coordinate is outside signed Q16.16 range.");
        return (int)scaled;
    }

    private static int Dot(int[] left, int[] right)
    {
        long x = ((long)left[0] * right[0]) >> 16;
        long y = ((long)left[1] * right[1]) >> 16;
        long z = ((long)left[2] * right[2]) >> 16;
        return unchecked((int)(x + y + z));
    }

    private static int[] Cross(int[] left, int[] right)
    {
        return new[]
        {
            unchecked((int)(((long)left[1] * right[2] >> 16) - ((long)left[2] * right[1] >> 16))),
            unchecked((int)(((long)left[2] * right[0] >> 16) - ((long)left[0] * right[2] >> 16))),
            unchecked((int)(((long)left[0] * right[1] >> 16) - ((long)left[1] * right[0] >> 16)))
        };
    }

    private static int[] Subtract(int[] left, int[] right)
    {
        return new[]
        {
            unchecked(left[0] - right[0]),
            unchecked(left[1] - right[1]),
            unchecked(left[2] - right[2])
        };
    }
}
