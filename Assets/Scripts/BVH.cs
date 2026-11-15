using System.Collections.Generic;
using UnityEngine;

public class BVH : MonoBehaviour
{
    public struct Node
    {
        public int left;
        public int right;
        public int id;
        public Bounds aabbox;
        public uint MortonCode;
    }

    private List<Node> tree = new List<Node>();

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
                leaf.aabbox = GeometryUtility.CalculateBounds(vertices, Matrix4x4.identity);
                leaf.MortonCode = FindMorton(leaf.aabbox);

                tree.Add(leaf);
                leaf_index++;
            }
        }

        tree.Sort((a, b) => a.MortonCode.CompareTo(b.MortonCode));

        createSubTree(0, leaf_index-1, tree);

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
            parentNode.aabbox = tree[parentNode.left].aabbox;
            parentNode.aabbox.Encapsulate(tree[parentNode.right].aabbox);
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

    uint FindMorton(Bounds box){
        Bounds scene_box = new Bounds(new Vector3(0,0,0), new Vector3(100, 100, 100));

        // Normalize the box center to [0,1] inside the scene bounds
        Vector3 c = box.center - scene_box.min;
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

    // Returns every leaf node whose AABB is intersected by the ray
    public List<Node> GetIntersectedLeaves(RTRay ray)
    {
        List<Node> hits = new List<Node>();
        if (tree.Count == 0) return hits;

        Ray r = new Ray(ray.origin, ray.direction);
        Stack<int> stack = new Stack<int>();
        stack.Push(tree.Count - 1); // root is the last node added

        while (stack.Count > 0)
        {
            Node n = tree[stack.Pop()];
            if (!n.aabbox.IntersectRay(r)) continue; // prune whole subtree

            if (n.left == -1 && n.right == -1)
            {
                hits.Add(n);
            }
            else
            {
                stack.Push(n.left);
                stack.Push(n.right);
            }
        }
        return hits;
    }

    void OnDrawGizmos()
    {
        if (tree==null) return;
        foreach(Node n in tree){
            if (n.left==-1 && n.right==-1){
                Gizmos.color = Color.green;
                Gizmos.DrawWireCube(n.aabbox.center, n.aabbox.size);
            }
            else{
                Gizmos.color = Color.blue;
                Gizmos.DrawWireCube(n.aabbox.center, n.aabbox.size);
            }
        }
        Gizmos.color = Color.red;
        Gizmos.DrawWireCube(new Vector3(0,0,0), new Vector3(100, 100, 100));
    }
}
