using System.Collections.Generic;
using UnityEngine;

public struct RTRay
{
    public Vector3 origin;
    public Vector3 direction;
    public Vector3 ray_col;
    public Vector3 accum_col;
}

public struct Hit
{
    public float distance;
    public Vector3 position;
    public Vector3 surface_normal;   // geometric (face) normal
    public Vector3 shading_normal;   // interpolated vertex normal
    public int material_id;
}

public class FakePGA : MonoBehaviour
{

    // Lists to hold objects and primitives
    public List<RTObject> loadedMeshes = new List<RTObject>();
    public Triangle[] all_tri = new Triangle[0];

    // Primary ray settings
    public float fov;
    public int X_res;
    public int Y_res;

    public GameObject rtCam;

    // Wall-clock time of the last Frame() call, in milliseconds (read-only, shown in the Inspector)
    public float lastFrameMs;
    // Wall-clock time of the most recent GeneratePrimaries / BounceBVH call, in milliseconds
    public float lastPrimariesMs;
    public float lastBounceMs;
    public BVH bvh;

    public int num_bounces = 3;
    

    // Start is called once before the first execution of Update after the MonoBehaviour is created
    void Start()
    {
        // Find the tree in the scene
        bvh = Object.FindObjectsByType<BVH>(FindObjectsSortMode.None)[0];

        // Find all active instances of RTObject and populate the list
        RTObject[] foundScripts = Object.FindObjectsByType<RTObject>(FindObjectsSortMode.None);
        loadedMeshes.AddRange(foundScripts);

        // Hookup the camera with the tag "RTcam" to GeneratePrimaries
        rtCam = GameObject.FindWithTag("RTcam");
        if (rtCam == null)
        {
            Debug.LogError("FakePGA: no GameObject tagged RTcam found");
            return;
        }
        fov = rtCam.GetComponent<Camera>().fieldOfView;

        // Populate triangle array (BVH leaf ids index into it)
        List<Triangle> tris = new List<Triangle>();
        foreach(RTObject obj in loadedMeshes){
            tris.AddRange(obj.mesh.triangles);
        }
        all_tri = tris.ToArray();
    }

    // Update is called once per frame: trace a frame as soon as the BVH is ready
    void Update()
    {
        if (rtCam == null || bvh == null || !bvh.IsBuilt) return;
        Frame();
    }

    void Frame(){
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        RTRay[,] rays = GeneratePrimaries(rtCam, fov, X_res, Y_res);

        for (int i=0; i<num_bounces ;i++){
            // DrawDebugRays(rays);
            BounceBVH(rays);
        }

        RenderFrame(rays);

        lastFrameMs = (float)stopwatch.Elapsed.TotalMilliseconds;
    }


    void BounceBVH(RTRay[,] rays)
    {
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        const float EPSILON = 1e-7f;
        int width = rays.GetLength(0);
        int height = rays.GetLength(1);

        // Every ray of the frame is a separate work item; each (x, y) only writes its own rays[x, y]
        System.Threading.Tasks.Parallel.For(0, width * height, i => {
            int x = i / height;
            int y = i % height;
            {
                ref RTRay ray = ref rays[x, y];
                if (ray.ray_col == Vector3.zero) return;

                Hit first_hit;
                first_hit.surface_normal = new Vector3(0,0,0);
                first_hit.shading_normal = new Vector3(0,0,0);
                first_hit.material_id = 0; //material[0] Should be the background material
                first_hit.position = new Vector3(0,0,0);
                first_hit.distance = 1e10f;

                // Traversal tests triangles at the leaves and culls boxes beyond the closest hit
                bvh.ClosestHit(ray, all_tri, ref first_hit);

                // Update color
                ray.accum_col += Vector3.Scale(ray.ray_col, RTObject.materials[first_hit.material_id].emissionColor);
                ray.ray_col = Vector3.Scale(ray.ray_col, RTObject.materials[first_hit.material_id].diffuseColor);
                
                // Update ray
                if (first_hit.distance < 1e9f){
                    ray.origin = first_hit.position + (first_hit.surface_normal*1e-4f);
                    ray.direction -= first_hit.shading_normal * 2 * Vector3.Dot(ray.direction, first_hit.shading_normal);
                    ray.direction = PerturbDirection(ray.direction, (Mathf.PI/256f) * (0xFF - RTObject.materials[first_hit.material_id].smoothness));
                }
            }
        });

        lastBounceMs = (float)stopwatch.Elapsed.TotalMilliseconds;
    }

    // Möller–Trumbore, test only: returns true with distance t and barycentrics u, v when the
    // ray hits the triangle. Normals and position are left to MakeHit, which runs once per ray
    // for the closest hit instead of for every candidate. Called by BVH.ClosestHit at the leaves.
    public static bool IntersectTriangle(in Triangle tri, Vector3 origin, Vector3 direction,
                                         out float t, out float u, out float v)
    {
        const float EPSILON = 1e-7f;
        t = -1f; u = 0f; v = 0f;

        // Begin calculating determinant; also used for u
        Vector3 P = Vector3.Cross(direction, tri.E2);
        float det = Vector3.Dot(tri.E1, P);

        // Ray is parallel to the triangle plane
        if (det > -EPSILON && det < EPSILON) return false;

        float invDet = 1.0f / det;

        // Distance from V0 to ray origin
        Vector3 T = origin - tri.V0;

        // First barycentric coordinate
        u = Vector3.Dot(T, P) * invDet;
        if (u < 0.0f || u > 1.0f) return false;

        // Second barycentric coordinate
        Vector3 Q = Vector3.Cross(T, tri.E1);
        v = Vector3.Dot(direction, Q) * invDet;
        if (v < 0.0f || u + v > 1.0f) return false;

        // Distance along the ray to the hit point
        t = Vector3.Dot(tri.E2, Q) * invDet;
        return true;
    }

    // Builds the full Hit for the closest triangle from its t, u, v
    public static Hit MakeHit(in Triangle tri, in RTRay ray, float t, float u, float v)
    {
        Hit hit;
        hit.distance = t;
        hit.position = ray.origin + t * ray.direction;
        hit.surface_normal = Vector3.Cross(tri.E1, tri.E2);
        hit.surface_normal /= hit.surface_normal.magnitude;
        // Smooth shading: interpolate the vertex normals with the barycentrics
        hit.shading_normal = ((1f - u - v) * tri.N0 + u * tri.N1 + v * tri.N2).normalized;
        hit.material_id = tri.material_id;
        return hit;
    }

    //--------------------------------------------------------------

    private RTRay[,] GeneratePrimaries(GameObject camera, float fov, int X_res, int Y_res)
    {
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        Vector3 camera_origin = camera.transform.position;
        Vector3 camera_direction = camera.transform.forward;
        Vector3 right = camera.transform.right;
        Vector3 up = camera.transform.up;

        RTRay[,] rays = new RTRay[X_res, Y_res];
        float delta = (Mathf.PI * fov/180)/ Y_res;

        // TODO: Should be done with matrices
        for(int cur_x=0; cur_x<X_res; cur_x++){
            for(int cur_y=0; cur_y<Y_res; cur_y++){
                float deltax = (cur_x-X_res/2)*delta;
                float deltay = (cur_y-Y_res/2)*delta;
                Vector3 direction = (deltax*right + deltay*up) + camera_direction;
                direction /= direction.magnitude;
            
                rays[cur_x, cur_y].origin = camera_origin;
                rays[cur_x, cur_y].direction = PerturbDirection(direction, 0.001f);

                
                rays[cur_x, cur_y].ray_col = new Vector3(1, 1, 1);
                rays[cur_x, cur_y].accum_col = new Vector3(0, 0, 0);
            }
        }

        lastPrimariesMs = (float)stopwatch.Elapsed.TotalMilliseconds;
        return rays;
    }

    // Debug: one pixel per ray drawn over the Game view
    Texture2D debugTex;
    public int accumFrames = 2;
    Color[] accum;      // running sum of the current batch
    int accumCount = 0;

    void RenderFrame(RTRay[,] rays)
    {
        int w = rays.GetLength(0), h = rays.GetLength(1);
        if (debugTex == null || debugTex.width != w || debugTex.height != h)
        {
            debugTex = new Texture2D(w, h, TextureFormat.RGBA32, false);
            debugTex.filterMode = FilterMode.Point;
            accum = new Color[w * h];   // zero-filled by default
            accumCount = 0;
        }

        Vector3 c;
        for (int x = 0; x < w; x++)
        {
            for (int y = 0; y < h; y++)
            {
                c = rays[x, y].accum_col;
                accum[y * w + x] += new Color(c.x, c.y, c.z, 1.0f);
            }
        }

        if (++accumCount < accumFrames)
            return;

        // Batch complete: show the average, then start a new batch
        float inv = 1.0f / accumCount;
        for (int i = 0; i < accum.Length; i++)
            accum[i] *= inv;
        debugTex.SetPixels(accum);
        debugTex.Apply();

        System.Array.Clear(accum, 0, accum.Length);
        accumCount = 0;
    }

    void OnGUI()
    {
        if (debugTex != null)
            GUI.DrawTexture(new Rect(0, 0, Screen.width, Screen.height), debugTex, ScaleMode.ScaleToFit);
    }

    // Debug: draw every stride-th ray in the Scene view, colored by ray_col
    void DrawDebugRays(RTRay[,] rays, int stride = 40, float length = 0.25f, float duration = 10.0f)
    {
        for (int x = 0; x < rays.GetLength(0); x += stride)
        {
            for (int y = 0; y < rays.GetLength(1); y += stride)
            {
                Vector3 c = rays[x, y].ray_col;
                Debug.DrawRay(rays[x, y].origin, rays[x, y].direction.normalized * length, new Color(c.x, c.y, c.z), duration);
            }
        }
    }

    // UnityEngine.Random only works on the main thread, so each thread gets its own System.Random
    [System.ThreadStatic] static System.Random threadRng;    static int rngSeed = System.Environment.TickCount;

    static float RandomRange(float min, float max)
    {
        if (threadRng == null)
            threadRng = new System.Random(System.Threading.Interlocked.Increment(ref rngSeed));
        return min + (float)threadRng.NextDouble() * (max - min);
    }

    public static Vector3 PerturbDirection(Vector3 initial, float maxAngleRad)
    {
        // Get angle from z
        float cosTheta = RandomRange(Mathf.Cos(maxAngleRad), 1f);
        float sinTheta = Mathf.Sqrt(1f - cosTheta * cosTheta);

        // Get angle from x
        float phi = RandomRange(0f, 2*Mathf.PI);

        // Convert to cartesian
        Vector3 localDir = new Vector3(
            sinTheta * Mathf.Cos(phi),
            cosTheta,
            sinTheta * Mathf.Sin(phi)
        );

        // Rotation maps z axis to initial direction
        Quaternion rotationToNormal = Quaternion.FromToRotation(Vector3.up, initial);

        // Rotate to align
        return rotationToNormal * localDir;
    }

}
