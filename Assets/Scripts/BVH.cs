using System.Collections.Generic;
using UnityEngine;

public class BVH : MonoBehaviour
{
    public struct Box
    {
        public Vector3 min;
        public Vector3 max;
    }
    public struct Node
    {
        public int left;
        public int right;
        public int id;
        public Box aabbox;
        public uint MortonCode;
    }

    private List<Node> tree = new List<Node>();
    private Node[] nodes = new Node[0];

    // Set once createTree finishes, so FakePGA knows when it can start tracing
    public bool IsBuilt { get; private set; }

    // Start is called once before the first execution of Update after the MonoBehaviour is created
    void Start()
    {
        Invoke("createTree", 0.01f);
    }

    // Update is called once per frame
    void Update()
    {
        
    }

    void createTree(){
        Debug.Log("Starting tree gen");
        List<RTObject> meshes = GameObject.FindWithTag("FPGA").GetComponent<FakePGA>().loadedMeshes;
        Debug.Log(meshes);

        int leaf_index = 0;
        Vector3[] vertices = new Vector3[3];
        foreach(RTObject obj in meshes){
            foreach(Triangle triangle in obj.mesh.triangles){
                vertices[0] = triangle.V0;
                vertices[1] = triangle.V0 + triangle.E1;
                vertices[2] = triangle.V0 + triangle.E2;

                Node leaf;
                leaf.id = leaf_index;
                leaf.left = -1;
                leaf.right = -1;
                
                Bounds bounds = GeometryUtility.CalculateBounds(vertices, Matrix4x4.identity);
                
                leaf.aabbox.min = bounds.min;
                leaf.aabbox.max = bounds.max;

                leaf.MortonCode = FindMorton(leaf.aabbox);

                tree.Add(leaf);
                leaf_index++;
            }
        }

        tree.Sort((a, b) => a.MortonCode.CompareTo(b.MortonCode));

        createSubTree(0, leaf_index-1, tree);
        nodes = tree.ToArray();

        IsBuilt = true;

    } 

    int createSubTree(int begin, int end, List<Node> Morton){
        if (end < begin){
            throw new System.ArgumentException("End smaller than begin for morton sublist");
        }
        if (begin == end){
            return begin;
        }
        else{
            int split = findMortonSplit(Morton, begin, end);

            Node parentNode;
            parentNode.left = createSubTree(begin, split, Morton);
            parentNode.right = createSubTree(split+1, end, Morton);
            parentNode.aabbox = Union(tree[parentNode.left].aabbox, tree[parentNode.right].aabbox);
            parentNode.MortonCode = FindMorton(parentNode.aabbox);

            parentNode.id = tree.Count;
            tree.Add(parentNode);
            return parentNode.id;
        }
    }

    
    int findMortonSplit(List<Node> sorted, int first, int last)
    {
        //https://developer.nvidia.com/blog/thinking-parallel-part-iii-tree-construction-gpu/
        uint firstCode = sorted[first].MortonCode;
        uint lastCode  = sorted[last].MortonCode;

        // Identical Morton codes => split the range in the middle.
        if (firstCode == lastCode)
            return (first + last) >> 1;

        // Calculate the number of highest bits that are the same
        // for all objects, using the count-leading-zeros intrinsic.
        int commonPrefix = Clz(firstCode ^ lastCode);

        // Use binary search to find where the next bit differs.
        // Specifically, we are looking for the highest object that
        // shares more than commonPrefix bits with the first one.
        int split = first;
        int step = last - first;

        do
        {
            step = (step + 1) >> 1;
            int newSplit = split + step;

            if (newSplit < last)
            {
                int splitPrefix = Clz(firstCode ^ sorted[newSplit].MortonCode);
                if (splitPrefix > commonPrefix)
                    split = newSplit;
            }
        }
        while (step > 1);

        return split;
    }

    // Count leading zeros (stands in for CUDA's __clz)
    static int Clz(uint x)
    {
        if (x == 0) return 32;
        int n = 0;
        if (x <= 0x0000FFFFu) { n += 16; x <<= 16; }
        if (x <= 0x00FFFFFFu) { n += 8;  x <<= 8;  }
        if (x <= 0x0FFFFFFFu) { n += 4;  x <<= 4;  }
        if (x <= 0x3FFFFFFFu) { n += 2;  x <<= 2;  }
        if (x <= 0x7FFFFFFFu) { n += 1; }
        return n;
    }

    uint FindMorton(Box box){
        Bounds scene_box = new Bounds(new Vector3(0,0,0), new Vector3(10, 10, 10));

        // Normalize the box center to [0,1] inside the scene bounds
        Vector3 c = (box.min + box.max) * 0.5f - scene_box.min;
        Vector3 s = scene_box.size;
        float nx = (c.x / s.x);
        float ny = (c.y / s.y);
        float nz = (c.z / s.z);

        // Quantize each axis to 10 bits (0..1023)
        uint x = (uint)Mathf.Min(nx * 1024f, 1023f);
        uint y = (uint)Mathf.Min(ny * 1024f, 1023f);
        uint z = (uint)Mathf.Min(nz * 1024f, 1023f);

        // Interleave: ...z2y2x2 z1y1x1 z0y0x0  (x in the lowest bit)
        return (ExpandBits(z) << 2) | (ExpandBits(y) << 1) | ExpandBits(x);
    }

    // Spreads the bits of a 10bit uint
    uint ExpandBits(uint v){
        v = (v * 0x00010001u) & 0xFF0000FFu;
        v = (v * 0x00000101u) & 0x0F00F00Fu;
        v = (v * 0x00000011u) & 0xC30C30C3u;
        v = (v * 0x00000005u) & 0x49249249u;
        return v;
    }

    // Max traversal stack depth. 64 covers any scene below 2^33 triangles.
    const int STACK_SIZE = 64;

    // Closest-hit traversal: intersects triangles at the leaves as it goes and keeps the nearest
    // hit in `best`. A box is skipped when its entry distance is beyond the closest hit so far,
    // and the nearer child is visited first so that distance shrinks early. On return, best is
    // unchanged if nothing closer than its incoming distance was hit.
    // No heap allocation: both stacks live on the thread's stack.
    public void ClosestHit(in RTRay ray, Triangle[] tris, ref Hit best)
    {
        const float EPSILON = 1e-7f;
        if (nodes.Length == 0) return;

        // Per-ray constants for the slab test, computed once instead of per node and axis
        Vector3 o = ray.origin;
        Vector3 d = ray.direction;
        Vector3 inv = new Vector3(SafeInv(d.x), SafeInv(d.y), SafeInv(d.z));

        // Closest triangle so far: only t, u, v are kept; the Hit is built once at the end
        float bestT = best.distance;
        float bestU = 0f, bestV = 0f;
        int bestTri = -1;

        // Node index and box entry distance, pushed together
        System.Span<int> stack = stackalloc int[STACK_SIZE];
        System.Span<float> stackT = stackalloc float[STACK_SIZE];
        int sp = 0;

        int root = nodes.Length - 1; // root is the last node added
        if (!BoxRayIntersect(in nodes[root].aabbox, o, inv, bestT, out float tRoot)) return;
        stack[sp] = root; stackT[sp] = tRoot; sp++;

        while (sp > 0)
        {
            sp--;
            // A closer hit was found after this node was pushed: its whole subtree is behind it
            if (stackT[sp] > bestT) continue;

            ref readonly Node n = ref nodes[stack[sp]];

            if (n.left == -1 && n.right == -1)
            {
                if (FakePGA.IntersectTriangle(in tris[n.id], o, d, out float t, out float u, out float v)
                    && t > EPSILON && t < bestT)
                {
                    bestT = t; bestU = u; bestV = v; bestTri = n.id;
                }
                continue;
            }

            // Test the children here (not on pop) so they can be ordered by entry distance
            bool hitL = BoxRayIntersect(in nodes[n.left].aabbox, o, inv, bestT, out float tL);
            bool hitR = BoxRayIntersect(in nodes[n.right].aabbox, o, inv, bestT, out float tR);

            // Push the far child first so the near child is popped next
            if (hitL && hitR)
            {
                if (tL <= tR)
                {
                    stack[sp] = n.right; stackT[sp] = tR; sp++;
                    stack[sp] = n.left;  stackT[sp] = tL; sp++;
                }
                else
                {
                    stack[sp] = n.left;  stackT[sp] = tL; sp++;
                    stack[sp] = n.right; stackT[sp] = tR; sp++;
                }
            }
            else if (hitL) { stack[sp] = n.left;  stackT[sp] = tL; sp++; }
            else if (hitR) { stack[sp] = n.right; stackT[sp] = tR; sp++; }
        }

        if (bestTri >= 0)
            best = FakePGA.MakeHit(in tris[bestTri], in ray, bestT, bestU, bestV);
    }

    // 1/d, with near-zero components mapped to a huge same-signed value instead of inf.
    // For a ray parallel to a slab, (bound - o) * 1e30 is then hugely negative/positive when the
    // origin is inside the slab and lands beyond tMax when it is outside, so no special case
    // (and no 0 * inf = NaN) is needed in the slab test.
    static float SafeInv(float d)
    {
        if (d > -1e-8f && d < 1e-8f) return d < 0f ? -1e30f : 1e30f;
        return 1f / d;
    }

    // Slab test, unrolled: true if the ray enters the box within [0, tMax]; tEntry is the entry
    // distance (0 when the origin is inside). Accepts tNear == tFar so zero-thickness boxes of
    // axis-aligned triangles still register hits.
    static bool BoxRayIntersect(in Box box, Vector3 o, Vector3 inv, float tMax, out float tEntry)
    {
        float tx0 = (box.min.x - o.x) * inv.x, tx1 = (box.max.x - o.x) * inv.x;
        float ty0 = (box.min.y - o.y) * inv.y, ty1 = (box.max.y - o.y) * inv.y;
        float tz0 = (box.min.z - o.z) * inv.z, tz1 = (box.max.z - o.z) * inv.z;

        // Per-axis entry/exit (swap for negative direction)
        float xn = tx0 < tx1 ? tx0 : tx1, xf = tx0 < tx1 ? tx1 : tx0;
        float yn = ty0 < ty1 ? ty0 : ty1, yf = ty0 < ty1 ? ty1 : ty0;
        float zn = tz0 < tz1 ? tz0 : tz1, zf = tz0 < tz1 ? tz1 : tz0;

        float tNear = xn > yn ? xn : yn; tNear = tNear > zn ? tNear : zn; tNear = tNear > 0f ? tNear : 0f;
        float tFar  = xf < yf ? xf : yf; tFar  = tFar  < zf ? tFar  : zf; tFar  = tFar < tMax ? tFar : tMax;

        tEntry = tNear;
        return tNear <= tFar;
    }

    // Smallest box enclosing both boxes
    Box Union(Box b1, Box b2){
        Box result;
        result.min = Vector3.Min(b1.min, b2.min);
        result.max = Vector3.Max(b1.max, b2.max);
        return result;
    }

    // void OnDrawGizmos()
    // {
    //     if (tree==null) return;
    //     foreach(Node n in tree){
    //         if (n.left==-1 && n.right==-1){
    //             Gizmos.color = Color.green;
    //             Gizmos.DrawWireCube((n.aabbox.min + n.aabbox.max) * 0.5f, n.aabbox.max - n.aabbox.min);
    //         }
    //         else{
    //             Gizmos.color = Color.blue;
    //             Gizmos.DrawWireCube((n.aabbox.min + n.aabbox.max) * 0.5f, n.aabbox.max - n.aabbox.min);
    //         }
    //     }
    //     Gizmos.color = Color.red;
    //     Gizmos.DrawWireCube(new Vector3(0,0,0), new Vector3(100, 100, 100));
    // }
}
