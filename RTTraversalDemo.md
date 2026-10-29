# Traversal and shading demo

Open `Assets/Scenes/TI_Shading_Demo.unity` and press Play. The Game view shows closest-hit material colors on the left and diffuse lighting with shadows on the right. The Console prints traversal statistics, and the comparison image is written to `RTDemoComparison.png` in the project root.

The demo scene copies the existing `SampleScene`. `FakePGA` is disabled only in the copy, and a `TI_Shading_Demo` object runs the new component. The original scene, `FakePGA.cs`, and `RTCore_mesh.cs` are unchanged. `RTCore > Prepare Traversal Demo` recreates the demo scene from `SampleScene`; save your current scene first.

## Implementation

The component reads world-space triangles and material data from `RTCore_mesh` after its first Update. It uses mesh-level axis-aligned bounding boxes to reject triangle groups, Moller-Trumbore intersection tests to select the closest hit, and Lambert diffuse shading with shadow rays. This is a CPU software prototype, not a full BVH or FPGA implementation. Lighting is a simplified model rather than a match for Unity's built-in renderer.

## Validation

Tested interactively in Unity 6000.6.5f1 using the actual scene:

- 108 triangles; 160 x 90 primary rays per view.
- 14,352 hits and 1,745 shadowed pixels.
- 193,722 primary triangle tests versus 1,555,200 brute-force tests: 87.5% skipped in the latest run.
- 0 mismatches across 100 sampled primary rays between bounding-box traversal and brute force.
- No compile or runtime errors reported in the Console during the run.

Test counts can vary with object enumeration order. The comparison shares its triangle intersection routine between both traversal paths, so it tests bounding-box rejection consistency rather than independently proving the intersection formula.

The repository specifies Unity 6000.3.25f1, which was not installed on the test machine. The included demo scene was saved with 6000.6.5f1; compatibility with 6000.3.25f1 has not been verified. Local editor-generated package and project setting upgrades are excluded from this contribution.
