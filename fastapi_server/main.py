from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
import asyncio
import json
import base64
import traceback
from pydantic import BaseModel
from typing import Optional
import firebase_admin
from firebase_admin import credentials, db
from datetime import datetime, timedelta
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from supabase import create_client
from fastapi import UploadFile, File
import shutil
import uuid
import os
import cv2
import PIL.Image
import io
import google.generativeai as genai
from dotenv import load_dotenv
from detection import detect_objects, process_detections
from message import build_final_message

load_dotenv()

# --------------------
# GEMINI CONFIG
# --------------------
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
GEMINI_MODEL   = "gemini-2.5-flash"

genai.configure(api_key=GEMINI_API_KEY)
gemini = genai.GenerativeModel(GEMINI_MODEL)

GEMINI_PROMPT = """You are assisting a visually impaired person navigate safely.

Analyze the image carefully and return STRICT JSON ONLY:

{
  "objects": [
    {"name": "...", "position": "left/center/right", "risk": "low/medium/high"}
  ],
  "instruction": "short spoken warning"
}

Rules for "name":
- Be SPECIFIC — never use generic words like "barrier" or "obstacle"
- Use the exact real-world name: wall, gate, parked car, motorbike, person, dog, tree,
  wooden door, glass door, iron fence, construction cone, trash can, desk, chair,
  staircase, ramp, puddle, pothole, electric pole, pillar, etc.
- If you truly cannot identify it, say "unidentified object"

Rules for "position":
- left = object is in the left third of the frame
- center = object is directly ahead
- right = object is in the right third of the frame

Rules for "risk":
- high = close to camera, blocking the path, or dangerous
- medium = present but not immediately blocking
- low = far away or not in the path

Rules for "instruction":
- One short spoken sentence, max 10 words
- Name the object + direction + action (e.g. "parked car on the left move right")
- No punctuation — it will be read aloud by text to speech
- Do NOT say "barrier" or "obstacle" — always name the real object

Only include objects relevant to safe navigation.
DO NOT return anything except raw JSON. DO NOT wrap in markdown or code blocks."""


def safe_parse_gemini(text: str) -> dict:
    """Safely parse Gemini JSON response, strip markdown if present."""
    try:
        text = text.strip()
        # Strip ```json ... ``` wrapper if Gemini adds it despite instructions
        if text.startswith("```"):
            lines = text.split("\n")
            text = "\n".join(lines[1:-1]) if lines[-1] == "```" else "\n".join(lines[1:])
        return json.loads(text.strip())
    except Exception:
        print("⚠️ Invalid JSON from Gemini:", text)
        return {"objects": [], "instruction": "Proceed carefully"}

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY")

supabase = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)
# --------------------
# FIREBASE INIT
# --------------------
cred = credentials.Certificate("firebase_key.json")
if not firebase_admin._apps:
    firebase_admin.initialize_app(
        cred,
        {"databaseURL": "https://fyp-assistive-device-default-rtdb.firebaseio.com/"}
    )
EMAIL_SENDER = os.getenv("EMAIL_SENDER")
EMAIL_PASSWORD = os.getenv("EMAIL_PASSWORD")

# --------------------
# FASTAPI INIT
# --------------------
app = FastAPI()

# --------------------
# GLOBALS
# --------------------
last_fall_time = None
FALL_COOLDOWN_SECONDS = 10

# Heat detection tuning
HEAT_ON_DELTA_C = 5.0
HEAT_OFF_DELTA_C = 3.0
EMA_ALPHA = 0.25
MIN_VALID_OBJECT_C = -20
MAX_VALID_OBJECT_C = 300

# Obstacle tuning
OBSTACLE_THRESHOLD_CM = 50.0
OBSTACLE_ON_COUNT = 2
OBSTACLE_OFF_COUNT = 2

# Camera trigger range — Gemini/YOLO fires whenever object is inside this band.
# Below CAMERA_MIN or above CAMERA_MAX no trigger fires.
# CAMERA_COOLDOWN_S prevents flooding while the object stays in range.
CAMERA_MIN_DIST_CM = 90.0    # below this camera is suppressed
CAMERA_MAX_DIST_CM = 250.0   # above this camera is suppressed
CAMERA_COOLDOWN_S  = 8.0     # minimum seconds between consecutive triggers in-range

# Minimum seconds between camera triggers for the SAME alert category (obstacle/heat/drop).
# Prevents flooding Gemini every 500 ms while an alert is active.
ALERT_CAMERA_COOLDOWN_S = 8.0

# Vocal alert threshold — sensor alert only speaks when object is this close.
# At longer distances Gemini/YOLO handles awareness via staged camera triggers.
OBSTACLE_VOCAL_ALERT_CM = 70.0


# Shared state for Flutter
latest_status = {
    "alert": False,
    "message": "",
    "reason": None,
    "distance": None,
    "ambient_temp": None,
    "object_temp": None,
    "delta_temp": None,
    "heat_active": False,
    "fall_active": False,
    "updated_at": None
}

# --------------------
# WEBSOCKET MANAGER
# --------------------
class ConnectionManager:
    def __init__(self):
        self.active: list[WebSocket] = []

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active.append(ws)

    def disconnect(self, ws: WebSocket):
        if ws in self.active:
            self.active.remove(ws)

    async def broadcast(self, msg: dict):
        for ws in list(self.active):
            try:
                await ws.send_json(msg)
            except Exception:
                self.disconnect(ws)

manager = ConnectionManager()

# Internal running state
_state = {
    "heat_active":          False,
    "ema_delta":            None,
    "obstacle_hits":        0,
    "obstacle_clears":      0,

    # ── Per-category gates ──────────────────────────────────────────────────
    # Prevent the same category from re-broadcasting camera trigger while
    # it is already active / Gemini is still processing.
    "camera_in_flight":     False,   # True = /detect is currently running
    "camera_range_last":    None,    # datetime of last range-based camera trigger

    "alert_camera_last": {           # {reason: datetime} — cooldown per category
        "obstacle": None,
        "heat":     None,
        "drop":     None,
        "fall":     None,
    },
}

# --------------------
# DATA MODELS
# --------------------
class SensorData(BaseModel):
    device_id: Optional[str] = None
    distance: float
    # accelerometer axes
    ax: Optional[float] = None
    ay: Optional[float] = None
    az: Optional[float] = None
    acc_magnitude: Optional[float] = None  # kept for backwards compatibility
    fall_risk: Optional[bool] = None
    fall_detected: bool
    drop_ahead_alert: Optional[bool] = None
    floor_delta: Optional[float] = None    # kept for backwards compatibility
    floor_status: Optional[str] = None     # "normal", "drop", etc.
    ambient_temp: Optional[float] = None
    object_temp: Optional[float] = None
    heat_alert: Optional[bool] = None
    obstacle_alert: Optional[bool] = None
    emergency_alert: Optional[bool] = None
    approach_rate: Optional[float] = None  # cm/s closing speed
    notify_caregiver: Optional[bool] = None
    priority: Optional[str] = None
    cam_triggered: Optional[bool] = None
    cam_state: Optional[str] = None


class LocationData(BaseModel):
    lat: float
    lon: float
    
# --------------------
# ROUTES
# --------------------
@app.get("/")
def home():
    return {"status": "FastAPI running successfully"}


@app.get("/latest-status")
def get_latest_status():
    return latest_status


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    print(f"[WS] Client connected — total: {len(manager.active)}")
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(websocket)
        print(f"[WS] Client disconnected — total: {len(manager.active)}")


@app.post("/update-location")
def update_location(data: LocationData):
    db.reference("current_location").set({
        "lat": data.lat,
        "lon": data.lon,
        "updated_at": datetime.now().isoformat()
    })
    return {"status": "location updated"}


# --------------------
# HELPERS
# --------------------
def _now_iso():
    return datetime.now().isoformat()


def _clamp_temp(t: float) -> float:
    if t < MIN_VALID_OBJECT_C:
        return MIN_VALID_OBJECT_C
    if t > MAX_VALID_OBJECT_C:
        return MAX_VALID_OBJECT_C
    return t


def _compute_heat(ambient, obj, single_temp):
    if ambient is not None and obj is not None:
        ambient = float(ambient)
        obj = _clamp_temp(float(obj))
        delta = obj - ambient

        if _state["ema_delta"] is None:
            _state["ema_delta"] = delta
        else:
            _state["ema_delta"] = (EMA_ALPHA * delta) + ((1 - EMA_ALPHA) * _state["ema_delta"])

        smooth_delta = _state["ema_delta"]

        if not _state["heat_active"] and smooth_delta >= HEAT_ON_DELTA_C:
            _state["heat_active"] = True
        elif _state["heat_active"] and smooth_delta <= HEAT_OFF_DELTA_C:
            _state["heat_active"] = False

        return _state["heat_active"], round(smooth_delta, 2), ambient, obj

    if single_temp is not None:
        t = _clamp_temp(float(single_temp))
        return t >= 35.0, None, None, t

    return False, None, None, None


def _compute_obstacle(distance_cm: float) -> bool:
    if distance_cm < OBSTACLE_THRESHOLD_CM:
        _state["obstacle_hits"] += 1
        _state["obstacle_clears"] = 0
    else:
        _state["obstacle_clears"] += 1
        _state["obstacle_hits"] = 0

    if _state["obstacle_hits"] >= OBSTACLE_ON_COUNT:
        return True
    if _state["obstacle_clears"] >= OBSTACLE_OFF_COUNT:
        return False

    return bool(latest_status.get("message") == "Obstacle very close")


def get_device_mapping(device_id: str):
    try:
        res = (
            supabase
            .table("devices")
            .select("user_id, caregiver_email")
            .eq("device_id", device_id)
            .single()
            .execute()
        )

        if res.data:
            return res.data["user_id"], res.data["caregiver_email"]

    except Exception as e:
        print("Supabase device lookup error:", e)

    return None, None




def send_email_to_caregiver(to_email, location, timestamp):
    if not to_email or not location:
        return
    lat = location.get("lat")
    lon = location.get("lon")
    map_link = f"https://www.google.com/maps?q={lat},{lon}"

    subject = "🚨 EMERGENCY ALERT: User Unresponsive"
    body = f"""
        An emergency has been detected.

        Status: User unresponsive
        Time: {timestamp}

        Last known location:
        {map_link}

        Please check immediately.
        """

    msg = MIMEMultipart()
    msg["From"] = EMAIL_SENDER
    msg["To"] = to_email
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain"))

    try:
        server = smtplib.SMTP("smtp.gmail.com", 587)
        server.starttls()
        server.login(EMAIL_SENDER, EMAIL_PASSWORD)
        server.send_message(msg)
        server.quit()
        print("✅ Email sent to:", to_email)
    except Exception as e:
        print("❌ Email send failed:", e)


# --------------------
# SENSOR DATA ROUTE
# --------------------
@app.post("/sensor-data")
async def receive_sensor_data(data: SensorData):
    global last_fall_time

    now = datetime.now()
    alert_message = ""

    # camera debug
    if data.cam_triggered:
        print(f"[CAM] >>> CAMERA TRIGGERED | state={data.cam_state} | distance={data.distance}cm | close_count included in payload")

    # 1) FALL (highest priority)
    fall_active = bool(data.fall_detected)
    if fall_active:
        alert_message = "User unresponsive"
        latest_status["reason"] = "no_movement_detected"

        if (not last_fall_time) or ((now - last_fall_time) > timedelta(seconds=FALL_COOLDOWN_SECONDS)):
            last_fall_time = now
            
            user_id, caregiver_email = get_device_mapping(data.device_id)
            if not user_id:
                print("⚠️ Unknown device:", data.device_id)
                return {"error": "Unknown device"}

            location = db.reference("current_location").get()

            db.reference("emergency_events").push({
                "type": "unresponsive",
                "alert": "User unresponsive",
                "timestamp": now.isoformat(),
                "device_id": data.device_id,
                "distance": data.distance,
                "ambient_temp": data.ambient_temp,
                "object_temp": data.object_temp,
                "acc_magnitude": data.acc_magnitude,
                "fall_risk": data.fall_risk,
                "location": location
            })

            if caregiver_email:
                send_email_to_caregiver(
                    caregiver_email,
                    location,
                    now.isoformat()
                )
            else:
                print("⚠️ No caregiver email for device:", data.device_id)

    distance_cm = float(data.distance)

    # Spike detection now runs in firmware before the POST — faster, no extra round-trip.
    # Backend only receives the already-evaluated drop_ahead_alert flag.
    stairs_or_drop = bool(data.drop_ahead_alert)

    # ── Alert priority chain ────────────────────────────────────────────────
    # 2) DROP AHEAD — only fires on a real transition (spike), with a cooldown
    # so continuous large-distance readings don't keep re-triggering the alert.
    if stairs_or_drop and not fall_active:
        alert_message = "Drop or stairs ahead. Watch your step."
        latest_status["reason"] = "drop"

    # 3) HEAT — more dangerous than obstacle
    elif data.heat_alert and not fall_active:
        alert_message = "Heat source nearby. Be careful."
        latest_status["reason"] = "heat"

    # 4) OBSTACLE — vocal alert only when within OBSTACLE_VOCAL_ALERT_CM (60 cm).
    # At longer distances Gemini/YOLO handles awareness via staged camera triggers.
    elif data.obstacle_alert and not fall_active and distance_cm <= OBSTACLE_VOCAL_ALERT_CM:
        alert_message = "Object very close, stop moving."
        latest_status["reason"] = "obstacle"

    else:
        if not fall_active:
            latest_status["reason"] = None

    # Calculate delta temp for display
    delta_temp = None
    if data.ambient_temp is not None and data.object_temp is not None:
        delta_temp = round(float(data.object_temp) - float(data.ambient_temp), 2)

    latest_status["alert"] = (alert_message != "")
    latest_status["message"] = alert_message
    latest_status["distance"] = distance_cm
    latest_status["ambient_temp"] = data.ambient_temp
    latest_status["object_temp"] = data.object_temp
    latest_status["delta_temp"] = delta_temp
    latest_status["heat_active"] = bool(data.heat_alert)
    latest_status["fall_active"] = fall_active
    latest_status["updated_at"] = _now_iso()

    # ── Camera trigger logic ────────────────────────────────────────────────
    # Fires whenever object is inside the 90–250 cm range, with an 8 s cooldown.
    # Fall/drop: always skip — vocal alert already active.
    # Out of range: skip silently.
    if fall_active or stairs_or_drop:
        print(f"⚠️ Fall/Drop — skipping camera trigger (fall={fall_active} drop={stairs_or_drop})")

    elif not (CAMERA_MIN_DIST_CM <= distance_cm <= CAMERA_MAX_DIST_CM):
        pass  # outside active range — no log spam

    elif manager.active and not _state["camera_in_flight"]:
        last_t  = _state["camera_range_last"]
        elapsed = (now - last_t).total_seconds() if last_t else float("inf")

        if elapsed >= CAMERA_COOLDOWN_S:
            _state["camera_range_last"] = now
            print(f"📸 Range trigger — object at {distance_cm:.0f} cm (cooldown ok, {len(manager.active)} client(s))")
            asyncio.create_task(manager.broadcast({"capture": True, "distance": int(distance_cm)}))
        else:
            print(f"⏳ Range cooldown — {CAMERA_COOLDOWN_S - elapsed:.1f}s remaining (object at {distance_cm:.0f} cm)")

    return {
        "message": "Data received",
        "alert": alert_message,
        "heat_active": bool(data.heat_alert),
        "obstacle_active": bool(data.obstacle_alert),
        "fall_active": fall_active,
        "delta_temp": delta_temp,
        "priority": data.priority
    }
@app.post("/detect")
async def detect(request: Request):

    if _state["camera_in_flight"]:
        return {"message": "camera busy", "skipped": True}

    _state["camera_in_flight"] = True
    file_path = None

    try:
        # 1. Receive image
        file_path = f"temp_{uuid.uuid4()}.jpg"
        body = await request.body()

        if len(body) < 1000:
            return {"error": "image too small"}

        with open(file_path, "wb") as f:
            f.write(body)

        # 2. Decode image
        img = cv2.imread(file_path)
        if img is None:
            return {"error": "invalid image"}

        # Resize for speed
        h, w = img.shape[:2]
        max_dim = 512
        if max(h, w) > max_dim:
            scale = max_dim / max(h, w)
            img = cv2.resize(img, (int(w * scale), int(h * scale)))

        cv2.imwrite(file_path, img)

        # 3. Get sensor distance
        sensor_distance = latest_status.get("distance") or 0

        # --------------------------------------------------
        # ✅ YOLO DETECTION (MAIN LOGIC)
        # --------------------------------------------------
        yolo_detections = detect_objects(file_path)
        detections = process_detections(yolo_detections)

        print("🔍 YOLO detections:", detections)

        # Build simple message
        if detections:
            instruction = ". ".join(
                f"{d['label']} {d['distance']} {d['position']}"
                for d in detections
            )
        else:
            instruction = "Path is clear"

        # Convert to response format
        objects = [
            {
                "name": d["label"],
                "position": d["position"],
                "risk": "high" if d["distance"] != "far" else "low"
            }
            for d in detections
        ]

        has_alert = any(o["risk"] == "high" for o in objects)

        # Update global state
        latest_status.update({
            "alert": has_alert,
            "message": instruction,
            "reason": objects[0]["name"] if objects else "safe",
            "distance": sensor_distance,
            "updated_at": _now_iso()
        })

        return {
            "alert": has_alert,
            "message": instruction,
            "objects": objects,
            "source": "yolo",
            "distance_cm": sensor_distance
        }

    except Exception as e:
        print("❌ Detection error:", str(e))
        return {"error": str(e)}

    finally:
        _state["camera_in_flight"] = False
        if file_path and os.path.exists(file_path):
            os.remove(file_path)
            
            
""" @app.post("/detect")
async def detect(request: Request):

    # ── Camera gate — reject parallel calls ────────────────────────────────
    if _state["camera_in_flight"]:
        print("⏳ /detect blocked — Gemini already in flight")
        return {"message": "camera busy", "skipped": True}
    _state["camera_in_flight"] = True

    file_path = None

    try:
        # --------------------------------------------------
        # 1. Receive image
        # --------------------------------------------------
        print("📥 Image received")
        file_path = f"temp_{uuid.uuid4()}.jpg"

        body = await request.body()
        print(f"📥 Body size: {len(body)} bytes")

        if len(body) < 1000:
            print("❌ Image too small — likely corrupt or empty")
            return {"error": "image too small"}

        with open(file_path, "wb") as f:
            f.write(body)


        # --------------------------------------------------
        # 2. Decode + resize with OpenCV
        # --------------------------------------------------
        img = cv2.imread(file_path)
        if img is None:
            print("❌ cv2 could not decode image")
            return {"error": "invalid image"}

        print(f"📐 Shape: {img.shape[1]}x{img.shape[0]} px")

        print("📏 Resizing image...")
        h, w = img.shape[:2]
        max_dim = 512
        if max(h, w) > max_dim:
            scale = max_dim / max(h, w)
            img = cv2.resize(img, (int(w * scale), int(h * scale)))

        # slight brightness boost for dark frames
        img = cv2.convertScaleAbs(img, alpha=1.2, beta=20)
        cv2.imwrite(file_path, img, [cv2.IMWRITE_JPEG_QUALITY, 85])
        print(f"📐 Saved resized image: {img.shape[1]}x{img.shape[0]} px")


        # --------------------------------------------------
        # 3. Grab real sensor distance
        # --------------------------------------------------
        sensor_distance = latest_status.get("distance") or 0
        print(f"📡 Sensor distance: {sensor_distance} cm")


        # --------------------------------------------------
        # 4. Try Gemini first
        # --------------------------------------------------
        objects     = None
        instruction = None
        source      = "gemini"

        try:
            # ── Gemini request log ──────────────────────────────────────────
            key_hint = GEMINI_API_KEY[:8] + "..." + GEMINI_API_KEY[-4:]
            print("=" * 60)
            print(f"🧠 GEMINI REQUEST")
            print(f"   model      : {GEMINI_MODEL}")
            print(f"   api_key    : {key_hint}")
            print(f"   image_size : {os.path.getsize(file_path)} bytes")
            print(f"   distance   : {int(round(sensor_distance))} cm")
            print(f"   timestamp  : {datetime.now().isoformat()}")
            print("=" * 60)

            # Load into RAM so the file handle is free before finally-cleanup
            with open(file_path, "rb") as f:
                pil_img = PIL.Image.open(io.BytesIO(f.read()))
                pil_img.load()

            prompt_with_distance = (
                GEMINI_PROMPT +
                f"\n\nSensor reading: nearest obstacle is approximately "
                f"{int(round(sensor_distance))} cm away."
            )

            t_start = datetime.now()

            def _call_gemini():
                return gemini.generate_content([prompt_with_distance, pil_img])

            response = await asyncio.to_thread(_call_gemini)

            elapsed_ms = int((datetime.now() - t_start).total_seconds() * 1000)

            # ── Gemini response log ─────────────────────────────────────────
            print("=" * 60)
            print(f"✅ GEMINI RESPONSE  ({elapsed_ms} ms)")
            print(f"   finish_reason : {getattr(response.candidates[0], 'finish_reason', 'N/A') if response.candidates else 'no candidates'}")
            print(f"   raw_text      :\n{response.text}")
            print("=" * 60)

            print("🔍 Parsing Gemini response...")
            parsed      = safe_parse_gemini(response.text)
            objects     = parsed.get("objects", [])
            instruction = parsed.get("instruction", "")
            print(f"📋 Parsed instruction : \"{instruction}\"")
            print(f"📋 Parsed objects     : {objects}")

            if not instruction:
                raise ValueError("Gemini returned empty instruction")

        except Exception as gemini_err:
            print("=" * 60)
            print(f"❌ GEMINI FAILED")
            print(f"   error_type : {gemini_err.__class__.__name__}")
            print(f"   error_msg  : {gemini_err}")
            print(f"   traceback  :\n{traceback.format_exc()}")
            print("=" * 60)
            print("🔁 Falling back to YOLO + message pipeline...")
            source = "yolo_fallback"

            # --------------------------------------------------
            # 4b. YOLO fallback
            # --------------------------------------------------
            try:
                yolo_outputs = detect_objects(file_path)
                detections   = process_detections(yolo_outputs)
                print("🔍 YOLO detections:", detections)

                detected_labels = [d["label"] for d in detections]
                result = await build_final_message(
                    detected_labels,
                    detections,
                    sensor_distance
                )

                instruction = result["scene_description"]
                alert_type  = result["alert_type"]
                # Convert YOLO result to Gemini-compatible objects list
                objects = [
                    {
                        "name":     d["label"],
                        "position": d["position"],
                        "risk":     "high" if alert_type != "safe" else "low"
                    }
                    for d in detections
                ]
                print("✅ YOLO fallback result:", instruction)

            except Exception as yolo_err:
                print("=" * 60)
                print(f"❌ YOLO FALLBACK FAILED")
                print(f"   error_type : {yolo_err.__class__.__name__}")
                print(f"   error_msg  : {yolo_err}")
                print(f"   traceback  :\n{traceback.format_exc()}")
                print("=" * 60)
                instruction = "Proceed carefully"
                objects     = []


        # --------------------------------------------------
        # 5. Build unified response
        # --------------------------------------------------
        objects     = objects or []
        instruction = instruction or "Proceed carefully"
        has_alert   = any(o.get("risk") == "high" for o in objects)
        top_reason  = objects[0]["name"] if objects else "safe"

        print(f"📊 Source={source} | alert={has_alert} | instruction={instruction}")


        # --------------------------------------------------
        # 6. Update Flutter shared status
        # --------------------------------------------------
        latest_status.update({
            "alert":      has_alert,
            "message":    instruction,
            "reason":     top_reason,
            "distance":   sensor_distance,
            "updated_at": _now_iso()
        })


        # --------------------------------------------------
        # 7. Return to app
        # --------------------------------------------------
        print("📡 Sending response to app")
        return {
            "alert":       has_alert,
            "message":     instruction,
            "reason":      top_reason,
            "objects":     objects,
            "source":      source,
            "distance_cm": sensor_distance
        }


    except Exception as e:
        print("❌ /detect unhandled error:", str(e))
        return {"error": str(e)}


    finally:
        _state["camera_in_flight"] = False   # always release gate
        if file_path and os.path.exists(file_path):
            os.remove(file_path) """