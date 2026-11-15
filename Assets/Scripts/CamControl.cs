using UnityEngine;
using UnityEngine.InputSystem;

public class CameraMovement : MonoBehaviour
{
    public float moveSpeed = 10f;

    void Update()
    {
        // Reads WASD or Arrow key inputs (-1 to 1)
        Keyboard kb = Keyboard.current;
        if (kb == null) return;
        float moveX = ((kb.dKey.isPressed || kb.rightArrowKey.isPressed) ? 1f : 0f)
                    - ((kb.aKey.isPressed || kb.leftArrowKey.isPressed)  ? 1f : 0f);
        float moveZ = ((kb.wKey.isPressed || kb.upArrowKey.isPressed)    ? 1f : 0f)
                    - ((kb.sKey.isPressed || kb.downArrowKey.isPressed)  ? 1f : 0f);

        // Moves relative to the camera's facing direction
        Vector3 move = transform.right * moveX + transform.forward * moveZ;
        
        // Keep movement flat on the Y-axis if building a top-down/RTS camera
        move.y = 0f; 

        transform.position += move.normalized * moveSpeed * Time.deltaTime;
    }
}