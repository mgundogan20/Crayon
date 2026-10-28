using System.Collections;
using System.Collections.Generic;
using System.IO;
using UnityEngine;

public class RTTraversalDemo : MonoBehaviour
{
    public GameObject rtCam;
    public Light sceneLight;
    public int width = 160;
    public int height = 90;
    public float pixelStep = 0.01f;

    struct TriData
    {
        public Vector3 v0, e1, e2, color, emission;
        public int id;
    }

    class MeshData
    {
        public TriData[] triangles;
        public Vector3 min, max;
    }

    struct RayHit
    {
        public bool found;
        public float distance;
        public Vector3 position, normal, color, emission;
        public int id;
    }

    List<MeshData> meshes = new List<MeshData>();
    Texture2D preview;
    int triangleCount;
    public bool completed { get; private set; }
    public int verificationMismatches { get; private set; }

    IEnumerator Start()
    {
        yield return null;
        RenderDemo();
    }

    [ContextMenu("Render Demo")]
    public void RenderDemo()
    {
        completed = false;
        if (rtCam == null)
            rtCam = GameObject.FindWithTag("RTcam");

        if (rtCam == null)
        {
            Debug.LogError("No camera tagged RTcam");
            return;
        }

        if (sceneLight == null)
        {
            Light[] lights = Object.FindObjectsByType<Light>(FindObjectsSortMode.None);
            foreach (Light light in lights)
                if (light.type == LightType.Point) { sceneLight = light; break; }
            if (sceneLight == null && lights.Length > 0)
                sceneLight = lights[0];
        }

        LoadMeshes();
        if (triangleCount == 0)
        {
            Debug.LogError("No triangles found. Check RTCore_mesh components.");
            return;
        }

        width = Mathf.Max(1, width);
        height = Mathf.Max(1, height);
        if (preview != null) Destroy(preview);
        preview = new Texture2D(width * 2, height, TextureFormat.RGB24, false);
        preview.filterMode = FilterMode.Point;

        int primaryTests = 0;
        int shadowTests = 0;
        int hits = 0;
        int shadows = 0;

        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                Vector3 origin = rtCam.transform.position;
                Vector3 direction = PixelDirection(x, y);
                RayHit hit = Trace(origin, direction, true, float.PositiveInfinity, -1, ref primaryTests);
                Vector3 flat = new Vector3(0.15f, 0.20f, 0.30f);
                Vector3 shaded = flat;

                if (hit.found)
                {
                    hits++;
                    flat = hit.color;
                    shaded = Shade(hit, ref shadowTests, ref shadows);
                }

                preview.SetPixel(x, y, ToColor(flat));
                preview.SetPixel(x + width, y, ToColor(shaded));
            }
        }

        preview.Apply();
        string filename = Path.GetFullPath(Path.Combine(Application.dataPath, "../RTDemoComparison.png"));
        File.WriteAllBytes(filename, preview.EncodeToPNG());

        int mismatches = VerifyTraversal();
        verificationMismatches = mismatches;
        completed = true;
        Debug.Log("T&I demo: " + triangleCount + " triangles, " + (width * height) +
                  " rays, " + hits + " hits, " + shadows + " shadowed pixels");
        long bruteForceTests = (long)width * height * triangleCount;
        float saved = 100f * (1f - (float)primaryTests / bruteForceTests);
        Debug.Log("Primary triangle tests: " + primaryTests + " vs " + bruteForceTests +
                  " brute force (" + saved.ToString("F1") + "% skipped)");
        Debug.Log("Shadow triangle tests: " + shadowTests);
        Debug.Log("Bounding box vs brute force: " + mismatches + " mismatches out of 100 rays");
        Debug.Log("Saved image: " + filename);
    }

    void LoadMeshes()
    {
        meshes.Clear();
        triangleCount = 0;
        RTCore_mesh[] objects = Object.FindObjectsByType<RTCore_mesh>(FindObjectsSortMode.None);

        foreach (RTCore_mesh obj in objects)
        {
            Triangle[] source = obj.rtMesh.triangles;
            if (source == null || source.Length == 0)
                continue;

            MeshData mesh = new MeshData();
            mesh.triangles = new TriData[source.Length];
            mesh.min = new Vector3(float.PositiveInfinity, float.PositiveInfinity, float.PositiveInfinity);
            mesh.max = new Vector3(float.NegativeInfinity, float.NegativeInfinity, float.NegativeInfinity);

            for (int i = 0; i < source.Length; i++)
            {
                Vector3 a = source[i].V0;
                Vector3 b = a + source[i].E1;
                Vector3 c = a + source[i].E2;
                mesh.min = Vector3.Min(mesh.min, Vector3.Min(a, Vector3.Min(b, c)));
                mesh.max = Vector3.Max(mesh.max, Vector3.Max(a, Vector3.Max(b, c)));
                mesh.triangles[i] = new TriData {
                    v0 = a, e1 = source[i].E1, e2 = source[i].E2,
                    color = obj.materialData.diffuseColor,
                    emission = obj.materialData.emissionColor,
                    id = triangleCount++
                };
            }

            mesh.min -= Vector3.one * 0.0001f;
            mesh.max += Vector3.one * 0.0001f;
            meshes.Add(mesh);
        }
    }

    Vector3 PixelDirection(int x, int y)
    {
        Transform cam = rtCam.transform;
        float dx = (x + 0.5f - width * 0.5f) * pixelStep;
        float dy = (y + 0.5f - height * 0.5f) * pixelStep;
        return cam.forward + dx * cam.right + dy * cam.up;
    }

    RayHit Trace(Vector3 origin, Vector3 direction, bool useBoxes, float maxDistance,
                 int ignoreId, ref int tests)
    {
        RayHit closest = new RayHit { distance = maxDistance, id = -1 };

        foreach (MeshData mesh in meshes)
        {
            if (useBoxes && !HitsBox(origin, direction, mesh.min, mesh.max, closest.distance))
                continue;

            foreach (TriData tri in mesh.triangles)
            {
                if (tri.id == ignoreId)
                    continue;

                tests++;
                float t;
                Vector3 normal;
                if (!HitsTriangle(origin, direction, tri, out t, out normal))
                    continue;

                if (t < closest.distance)
                {
                    closest.found = true;
                    closest.distance = t;
                    closest.position = origin + direction * t;
                    closest.normal = Vector3.Dot(normal, direction) > 0 ? -normal : normal;
                    closest.color = tri.color;
                    closest.emission = tri.emission;
                    closest.id = tri.id;
                }
            }
        }

        return closest;
    }

    bool HitsTriangle(Vector3 origin, Vector3 direction, TriData tri, out float t, out Vector3 normal)
    {
        t = 0;
        normal = Vector3.zero;
        Vector3 p = Vector3.Cross(direction, tri.e2);
        float det = Vector3.Dot(tri.e1, p);
        if (Mathf.Abs(det) < 0.0000001f)
            return false;

        float invDet = 1f / det;
        Vector3 s = origin - tri.v0;
        float u = Vector3.Dot(s, p) * invDet;
        if (u < 0 || u > 1)
            return false;

        Vector3 q = Vector3.Cross(s, tri.e1);
        float v = Vector3.Dot(direction, q) * invDet;
        if (v < 0 || u + v > 1)
            return false;

        t = Vector3.Dot(tri.e2, q) * invDet;
        if (t <= 0.0001f)
            return false;

        normal = Vector3.Cross(tri.e1, tri.e2).normalized;
        return true;
    }

    bool HitsBox(Vector3 origin, Vector3 direction, Vector3 min, Vector3 max, float maxDistance)
    {
        float near = 0;
        float far = maxDistance;

        for (int axis = 0; axis < 3; axis++)
        {
            float d = direction[axis];
            if (Mathf.Abs(d) < 0.00000001f)
            {
                if (origin[axis] < min[axis] || origin[axis] > max[axis])
                    return false;
                continue;
            }

            float a = (min[axis] - origin[axis]) / d;
            float b = (max[axis] - origin[axis]) / d;
            if (a > b) { float tmp = a; a = b; b = tmp; }
            near = Mathf.Max(near, a);
            far = Mathf.Min(far, b);
            if (near > far)
                return false;
        }

        return true;
    }

    Vector3 Shade(RayHit hit, ref int tests, ref int shadowCount)
    {
        Vector3 toLight;
        float lightDistance = float.PositiveInfinity;
        if (sceneLight != null && sceneLight.type == LightType.Point)
        {
            toLight = sceneLight.transform.position - hit.position;
            lightDistance = toLight.magnitude;
            toLight.Normalize();
        }
        else if (sceneLight != null)
            toLight = -sceneLight.transform.forward;
        else
            toLight = new Vector3(0.5f, 1f, -0.5f).normalized;

        float diffuse = Mathf.Max(0, Vector3.Dot(hit.normal, toLight));
        if (diffuse > 0)
        {
            Vector3 shadowOrigin = hit.position + hit.normal * 0.001f;
            RayHit blocker = Trace(shadowOrigin, toLight, true, lightDistance - 0.001f,
                                   hit.id, ref tests);
            if (blocker.found)
            {
                shadowCount++;
                diffuse = 0;
            }
        }

        return hit.color * (0.15f + 0.85f * diffuse) + hit.emission;
    }

    int VerifyTraversal()
    {
        int errors = 0;
        for (int i = 0; i < 100; i++)
        {
            int x = (i * 73) % width;
            int y = (i * 37) % height;
            int tests = 0;
            RayHit withBoxes = Trace(rtCam.transform.position, PixelDirection(x, y),
                                    true, float.PositiveInfinity, -1, ref tests);
            RayHit allTriangles = Trace(rtCam.transform.position, PixelDirection(x, y),
                                       false, float.PositiveInfinity, -1, ref tests);
            if (withBoxes.found != allTriangles.found ||
                (withBoxes.found && (withBoxes.id != allTriangles.id ||
                 Mathf.Abs(withBoxes.distance - allTriangles.distance) > 0.001f)))
                errors++;
        }
        return errors;
    }

    Color ToColor(Vector3 c)
    {
        return new Color(Mathf.Clamp01(c.x), Mathf.Clamp01(c.y), Mathf.Clamp01(c.z), 1);
    }

    void OnGUI()
    {
        if (preview == null)
            return;
        GUI.DrawTexture(new Rect(0, 0, Screen.width, Screen.height), preview, ScaleMode.ScaleToFit);
        GUI.Label(new Rect(15, 10, 250, 25), "Closest hit: material color");
        GUI.Label(new Rect(Screen.width / 2 + 15, 10, 250, 25), "Diffuse lighting + shadows");
    }
}
