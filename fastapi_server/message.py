import asyncio
import requests
from decision import decision_engine


# ----------------------------------
# SAFETY CONFIG
# ----------------------------------

CRITICAL_DISTANCE = 70   # cm
OLLAMA_MODEL   = "moondream"   # vision model — receives resized image + structured prompt
OLLAMA_TIMEOUT = 20.0


# ----------------------------------
# FALLBACK DESCRIPTION
# ----------------------------------

def fallback_description(detections, sensor_distance):
    """Build a plain-English fallback using the real ultrasonic distance,
    not the bounding-box estimate stored in d['distance']."""

    if not detections:
        return "Path appears clear."

    dist_str = f"{int(round(sensor_distance))} centimeters"

    phrases = []
    seen = set()

    for d in detections:

        if d["label"] in seen:
            continue

        seen.add(d["label"])

        phrases.append(
            f'{d["label"]} {dist_str} on your {d["position"]}'
        )

    return ". ".join(phrases[:2])


# ----------------------------------
# HARD SAFETY ALERTS
# ----------------------------------

def emergency_message(
   alert_type,
   sensor_distance
):

    if alert_type=="vehicle":
        return (
          f"Vehicle detected "
          f"{sensor_distance} centimeters ahead. Stop."
        )

    if alert_type=="dog":
        return (
          f"Dog nearby at "
          f"{sensor_distance} centimeters. Be careful."
        )

    if alert_type=="stairs":
        return "Stairs ahead. Slow down."

    if alert_type=="pole":
        return "Pole ahead. Avoid obstacle."

    if alert_type=="pothole":
        return "Pothole ahead. Watch your step."

    if alert_type=="trafficlight":
        return "Traffic light ahead. Check before crossing."

    if alert_type=="crosswalk":
        return "Crosswalk ahead. Proceed carefully."

    return "Obstacle very close."


# ----------------------------------
# LVLM DESCRIPTION
# ----------------------------------

async def moondream_description(detections, sensor_distance=0, img_b64=None):

    # deduplicate and build per-object description from YOLO output
    seen = set()
    object_lines = []
    for d in detections:
        if d["label"] in seen:
            continue
        seen.add(d["label"])
        object_lines.append(
            f"- {d['label']} on your {d['position']}"
        )

    if not object_lines:
        return None

    dist_cm = int(round(sensor_distance)) if sensor_distance else "unknown"
    objects_text = "\n".join(object_lines)

    prompt = (
        f"You are a navigation assistant for a visually impaired person.\n"
        f"Nearest obstacle: {dist_cm} centimeters away.\n"
        f"Detected objects:\n{objects_text}\n\n"
        f"Reply with ONE spoken sentence under 12 words. "
        f"State what is detected, its direction, and the distance. "
        f"No punctuation, no explanation, no extra text. Output the warning only."
    )

    payload = {
        "model": OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False
    }

    if img_b64:
        payload["images"] = [img_b64]

    def _call_ollama():
        r = requests.post(
            "http://localhost:11434/api/generate",
            json=payload,
            timeout=OLLAMA_TIMEOUT
        )
        return r.json()

    try:
        data = await asyncio.to_thread(_call_ollama)
        resp = data.get("response", "").strip()
        print(f"[OLLAMA:{OLLAMA_MODEL}] RESPONSE:", resp if resp else "(empty)")
        return resp if resp else None

    except Exception as e:
        print("Moondream timeout/fail:", e)
        return None


# ----------------------------------
# HYBRID FINAL MESSAGE ENGINE
# ----------------------------------

async def build_final_message(
 detected_objects,
 detections,
 sensor_distance,
 img_b64=None
):

    alert_type, priority = decision_engine(
       detected_objects,
       sensor_distance
    )


    # -------------------------------
    # HARD OVERRIDE FOR CLOSE HAZARDS
    # -------------------------------
    if (
      sensor_distance <= CRITICAL_DISTANCE
      and alert_type != "safe"
    ):
        desc = emergency_message(alert_type, sensor_distance)
        print(f"[MSG] PATH=HARD_OVERRIDE  alert={alert_type}  dist={sensor_distance}cm")
        print(f"[MSG] SPOKEN: {desc}")
        return {
            "alert_type": alert_type,
            "priority": "critical",
            "scene_description": desc
        }


    # -------------------------------
    # TRY LVLM
    # -------------------------------
    desc = await moondream_description(detections, sensor_distance, img_b64)

    if desc:
        print(f"[MSG] PATH=LLM({OLLAMA_MODEL})  alert={alert_type}  dist={sensor_distance}cm")
        print(f"[MSG] SPOKEN: {desc}")
    else:
        # -------------------------------
        # LVLM FAILED → FALLBACK
        # -------------------------------
        if alert_type != "safe":
            desc = emergency_message(alert_type, sensor_distance)
            print(f"[MSG] PATH=FALLBACK_EMERGENCY  alert={alert_type}  dist={sensor_distance}cm")
        else:
            desc = fallback_description(detections, sensor_distance)
            print(f"[MSG] PATH=FALLBACK_DESCRIPTION  alert={alert_type}  dist={sensor_distance}cm")
        print(f"[MSG] SPOKEN: {desc}")

    return {
        "alert_type": alert_type,
        "priority": priority,
        "scene_description": desc
    }