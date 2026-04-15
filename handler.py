import runpod
import subprocess
import requests
import time
import base64
import json
import os

COMFY_URL = "http://127.0.0.1:8188"

# Launch ComfyUI in background
def launch_comfy():
    subprocess.Popen(
        ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188"],
        cwd="/comfyui",
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

# Wait for ComfyUI to be ready
def wait_for_comfy():
    for _ in range(120):
        try:
            requests.get(f"{COMFY_URL}/system_stats")
            return True
        except:
            time.sleep(1)
    return False


def run_workflow(workflow):
    # Build correct ComfyUI payload
    payload = {
        "prompt": workflow.get("prompt", {}),
        "client_id": workflow.get("client_id", "runpod")
    }

    # Submit workflow
    try:
        res = requests.post(f"{COMFY_URL}/prompt", json=payload).json()
    except Exception as e:
        return {"error": "ComfyUI returned non‑JSON response"}

    # Return ComfyUI error instead of crashing
    if "prompt_id" not in res:
        return {
            "error": "ComfyUI rejected the workflow",
            "response": res
        }

    prompt_id = res["prompt_id"]

    # Poll for completion
    while True:
        history = requests.get(f"{COMFY_URL}/history/{prompt_id}").json()
        if prompt_id in history:
            break
        time.sleep(1)

    output = history[prompt_id]["outputs"]

    # Extract images
    images = []
    for node_id, node_output in output.items():
        if "images" in node_output:
            for img in node_output["images"]:
                filename = img["filename"]
                subfolder = img.get("subfolder", "")
                folder_type = img.get("type", "output")

                img_bytes = requests.get(
                    f"{COMFY_URL}/view?filename={filename}&subfolder={subfolder}&type={folder_type}"
                ).content

                images.append({
                    "filename": filename,
                    "base64": base64.b64encode(img_bytes).decode("utf-8")
                })

    return images

def handler(job):
    workflow = job["input"]["workflow"]

    # Start ComfyUI
    launch_comfy()

    # Wait for it to be ready
    if not wait_for_comfy():
        return {"error": "ComfyUI did not start in time"}

    # Run workflow
    images = run_workflow(workflow)

    return {
        "status": "success",
        "images": images
    }


runpod.serverless.start({"handler": handler})
