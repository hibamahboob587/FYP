import onnxruntime as ort

session = ort.InferenceSession("model/blind_assist_best.onnx")

print("Model loaded successfully ✅")