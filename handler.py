import runpod

def handler(job):
    return {"status": "ok", "input": job["input"]}

runpod.serverless.start({"handler": handler})
