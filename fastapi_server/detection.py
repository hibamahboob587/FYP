import onnxruntime as ort
import cv2
import numpy as np
import os


MODEL_PATH = os.path.join(os.path.dirname(__file__), "model", "blind_assist_best.onnx")
session = ort.InferenceSession(MODEL_PATH)

input_name = session.get_inputs()[0].name
output_name = session.get_outputs()[0].name


def preprocess(image_path):
    img = cv2.imread(image_path)

    if img is None:
        raise ValueError("Image not found or invalid")

    img = cv2.resize(img, (640, 640))
    img = img / 255.0
    img = np.transpose(img, (2, 0, 1))
    img = np.expand_dims(img, axis=0).astype(np.float32)

    return img


def detect_objects(image_path):
    img = preprocess(image_path)
    outputs = session.run([output_name], {input_name: img})
    print("OUTPUT SHAPE:", outputs[0].shape)  # ✅ HERE
    return outputs


CLASS_NAMES = [
    "bench","bin","chair","crosswalk","dog","door","footpath",
    "person","pole","pothole","stairs","stopsign",
    "table","trafficlight","vehicle"
]


def postprocess(outputs, conf=0.35):
    detections = []

    preds = outputs[0][0]  # shape: (84, 8400)
    preds = np.transpose(preds)  # (8400, 84)

    for det in preds:
        scores = det[4:]
        class_id = np.argmax(scores)
        confidence = float(scores[class_id])

        if confidence > conf:
            x_center = det[0] * 640
            width = det[2] * 640
            label = CLASS_NAMES[class_id]

            print(f"[YOLO] {label:15s}  conf={confidence:.2f}  x={x_center:.0f}  w={width:.0f}")

            detections.append({
                "label": label,
                "confidence": round(confidence, 2),
                "x_center": x_center,
                "width": width
            })

    if not detections:
        print("[YOLO] No detections above conf threshold")

    return detections


def get_position(x):
    if x < 213:
        return "left"
    elif x < 426:
        return "center"
    else:
        return "right"


def estimate_distance(width):
    if width > 300:
        return "50 cm"
    elif width > 150:
        return "100 cm"
    else:
        return "far"


def process_detections(outputs):
    raw = postprocess(outputs)
    final = []

    for obj in raw:
        final.append({
            "label": obj["label"],
            "position": get_position(obj["x_center"]),
            "distance": estimate_distance(obj["width"])
        })

    return final