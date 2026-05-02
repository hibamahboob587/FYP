from fastapi import FastAPI, Request
import uvicorn
import os

app = FastAPI()

@app.post("/test-image")
async def receive_test_image(request: Request):
    body = await request.body()

    if not body:
        return {"error": "No data received"}

    save_path = "test_captured.jpg"
    with open(save_path, "wb") as f:
        f.write(body)

    valid_jpeg = len(body) > 2 and body[0] == 0xFF and body[1] == 0xD8
    abs_path = os.path.abspath(save_path)

    print(f"\n{'='*50}")
    print(f"[IMAGE RECEIVED]")
    print(f"  Size     : {len(body)} bytes")
    print(f"  JPEG OK  : {valid_jpeg}")
    print(f"  Saved to : {abs_path}")
    print(f"{'='*50}\n")

    return {
        "status": "ok",
        "bytes_received": len(body),
        "jpeg_valid": valid_jpeg,
        "saved_to": abs_path
    }

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=9999)
