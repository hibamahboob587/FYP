#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiManager.h>
#include <WiFiClientSecure.h>
#include <Wire.h>
#include <Adafruit_MLX90614.h>
#include <MPU6050.h>

// ---------------- BACKEND ----------------
const char* sensorURL = "http://192.168.1.100:8000/sensor-data";

// ---------------- DEVICE ----------------
String device_id = "ESP32_001";

// ---------------- WIFI RESET ----------------
#define WIFI_RESET_PIN      0       // BOOT button on DevKit
#define WIFI_RESET_HOLD_MS  3000    // hold 3s to trigger reset

// ---------------- HC-SR04 ----------------
#define TRIG_PIN 5
#define ECHO_PIN 18
#define NUM_SAMPLES 5

// ---------------- OBJECTS ----------------
WiFiManager wm;
Adafruit_MLX90614 mlx = Adafruit_MLX90614();
MPU6050 mpu;

// ---------------- FALL LOGIC ----------------
#define IMPACT_G 2.0
#define STILLNESS_G 0.12
#define STILLNESS_TIME_MS 10000

bool possibleEmergency = false;
unsigned long noMotionStart = 0;

// -------- THRESHOLDS --------
#define ANOMALY_THRESHOLD     120.0
#define ALERT_THRESHOLD        90.0   // audio obstacle alert
#define EMERGENCY_THRESHOLD    60.0   // emergency audio alert
#define CLEAR_THRESHOLD       110.0

// -------- FLOOR / DROP DETECTION --------
float floorBaseline   = 0;
bool  baselineReady   = false;
float floorDelta      = 0;
int   dropCounter     = 0;
bool  drop_ahead_alert = false;

// -------- BATCH WINDOW DROP DETECTION --------
// Mirrors the backend rolling window — detects a spike vs the previous readings.
// Spike = latest distance rose by DROP_SPIKE_CM+ AND by DROP_SPIKE_RATIO+ of avg.
// Window resets after DROP_WINDOW_SIZE readings so stale readings don't linger.
#define DROP_WINDOW_SIZE   10
#define DROP_MIN_READINGS   3
#define DROP_SPIKE_CM      50.0
#define DROP_SPIKE_RATIO    0.40

float dropWindow[DROP_WINDOW_SIZE];
int   dropWindowIdx = 0;   // next write position (also doubles as current count when < SIZE)

// -------- FLAGS --------
bool fall_risk       = false;
bool heat_alert      = false;
bool obstacle_alert  = false;
bool emergency_alert = false;

// -------- APPROACH RATE --------
float prevDistance = 0;
float approachRate = 0;

// ---------------- DISTANCE ----------------
float getDistanceCM() {
  static int failCount = 0;
  float readings[NUM_SAMPLES];

  for (int i = 0; i < NUM_SAMPLES; i++) {
    digitalWrite(TRIG_PIN, LOW);
    delayMicroseconds(2);
    digitalWrite(TRIG_PIN, HIGH);
    delayMicroseconds(10);
    digitalWrite(TRIG_PIN, LOW);

    long duration = pulseIn(ECHO_PIN, HIGH, 65000);

    Serial.print("[US] Sample ");
    Serial.print(i);
    Serial.print(" duration: ");
    Serial.println(duration);

    if (duration == 0) {
      Serial.println("[WARN] No echo returned");
      readings[i] = 999;
      failCount++;
    } else {
      float speedOfSound = 0.03313 + 0.0000606 * mlx.readAmbientTempC();
      readings[i] = duration * speedOfSound / 2;
      Serial.print("[US] Distance sample: ");
      Serial.print(readings[i]);
      Serial.println(" cm");
    }
    delay(20);
  }

  if (failCount >= NUM_SAMPLES) {
    Serial.println("=================================");
    Serial.println("[ERROR] Ultrasonic appears FAILED");
    Serial.println("Check wiring / echo voltage divider / power");
    Serial.println("=================================");
    failCount = 0;
    return 999;
  }

  for (int i = 0; i < NUM_SAMPLES - 1; i++) {
    for (int j = i + 1; j < NUM_SAMPLES; j++) {
      if (readings[j] < readings[i]) {
        float t = readings[i];
        readings[i] = readings[j];
        readings[j] = t;
      }
    }
  }

  float medianDistance = readings[NUM_SAMPLES / 2];
  Serial.print("[US] Median Distance: ");
  Serial.print(medianDistance);
  Serial.println(" cm");

  if (medianDistance > 500 || medianDistance == 999)
    Serial.println("[WARN] Suspicious ultrasonic reading");

  failCount = 0;
  return medianDistance;
}

// ---------------- SENSOR SEND ----------------
void sendSensorData() {
  static bool fall_detected = false;

  float distance = getDistanceCM();

  // -------- ADAPTIVE BASELINE --------
  if (!drop_ahead_alert && distance < 150 && distance < 500)
    floorBaseline = 0.98 * floorBaseline + 0.02 * distance;

  floorDelta = distance - floorBaseline;

  // -------- DROP-AHEAD DETECTION (floor delta) --------
  // One-shot: stop accumulating once alert is already active so a continuous
  // large distance doesn't keep the counter growing forever.
  bool dropCondition = (floorDelta > 35) || (distance > 500);

  if (!drop_ahead_alert) {
    // Not yet alerting — accumulate hits
    if (dropCondition)
      dropCounter++;
    else if (floorDelta < 15 && distance < 500)
      dropCounter = 0;
  } else {
    // Already alerting — only reset when condition genuinely clears
    if (floorDelta < 15 && distance < 500)
      dropCounter = 0;
  }

  // -------- BATCH WINDOW DROP DETECTION --------
  // Faster than waiting for the backend — spike evaluated before HTTP POST.
  dropWindow[dropWindowIdx] = distance;
  dropWindowIdx++;

  bool windowDrop = false;
  if (dropWindowIdx >= DROP_MIN_READINGS) {
    float sum = 0;
    for (int i = 0; i < dropWindowIdx - 1; i++) sum += dropWindow[i];
    float avgPrev = sum / (dropWindowIdx - 1);
    float spike   = distance - avgPrev;
    if (spike >= DROP_SPIKE_CM && avgPrev > 0 && (spike / avgPrev) >= DROP_SPIKE_RATIO) {
      windowDrop = true;
      Serial.print("[DROP] Spike: avg="); Serial.print(avgPrev);
      Serial.print(" latest="); Serial.print(distance);
      Serial.print(" spike="); Serial.println(spike);
    }
  }

  if (dropWindowIdx >= DROP_WINDOW_SIZE) {
    Serial.println("[DROP] Window full — resetting batch");
    dropWindowIdx = 0;
  }

  drop_ahead_alert = (dropCounter >= 2) || windowDrop;

  if (drop_ahead_alert) {
    Serial.print("[WARN] DROP AHEAD | delta="); Serial.print(floorDelta);
    Serial.print(" dist="); Serial.println(distance);
  }

  // -------- APPROACH RATE --------
  approachRate = (prevDistance - distance) / 0.5;
  prevDistance = distance;

  // -------- IMU --------
  int16_t ax_raw, ay_raw, az_raw;
  mpu.getAcceleration(&ax_raw, &ay_raw, &az_raw);

  float ax = ax_raw / 16384.0;
  float ay = ay_raw / 16384.0;
  float az = az_raw / 16384.0;

  float accMagnitude = sqrt(ax * ax + ay * ay + az * az);
  float deviation    = abs(accMagnitude - 1.0);

  // -------- FALL LOGIC --------
  if (accMagnitude > IMPACT_G || deviation > 0.4) {
    possibleEmergency = true;
    noMotionStart = millis();
    Serial.println("[FALL] Impact detected — monitoring for stillness...");
  }

  if (possibleEmergency) {
    if (deviation < STILLNESS_G) {
      if (millis() - noMotionStart > STILLNESS_TIME_MS) {
        fall_detected = true;
        possibleEmergency = false;
        Serial.println("[FALL] FALL DETECTED — user unresponsive!");
      }
    } else {
      noMotionStart = millis();
    }
  }

  // -------- PREDICTIVE FALL RISK --------
  fall_risk = (accMagnitude > 1.15 || deviation > 0.25);

  // -------- TEMPERATURE --------
  float ambientTemp = mlx.readAmbientTempC();
  float objectTemp  = mlx.readObjectTempC();

  if (isnan(ambientTemp) || isnan(objectTemp)) {
    Serial.println("[ERROR] Temp sensor failed — skipping POST");
    return;
  }

  // -------- HEAT HAZARD --------
  float tempDelta = objectTemp - ambientTemp;
  heat_alert = (tempDelta > 8.0 || objectTemp > 38.0);
  if (heat_alert) {
    Serial.println("[WARN] HOT OBJECT WARNING");
    Serial.print("[WARN] Temp delta: "); Serial.println(tempDelta);
  }

  // -------- OBSTACLE TIER LOGIC --------
  obstacle_alert  = false;
  emergency_alert = false;

  if (distance <= EMERGENCY_THRESHOLD) {
    emergency_alert = true;
    obstacle_alert  = true;
  } else if (distance <= ALERT_THRESHOLD) {
    obstacle_alert = true;
  }

  // -------- PRIORITY --------
  String priority = "normal";
  if (fall_detected)         priority = "emergency";
  else if (drop_ahead_alert) priority = "critical";
  else if (emergency_alert)  priority = "critical";
  else if (obstacle_alert)   priority = "high";
  else if (fall_risk)        priority = "warning";

  // -------- DEBUG --------
  Serial.println("-------------");
  Serial.print("Distance: ");        Serial.println(distance);
  Serial.print("Baseline: ");        Serial.println(floorBaseline);
  Serial.print("Floor Delta: ");     Serial.println(floorDelta);
  Serial.print("Approach Rate: ");   Serial.println(approachRate);
  Serial.print("Drop Ahead: ");      Serial.println(drop_ahead_alert);
  Serial.print("Fall Risk: ");       Serial.println(fall_risk);
  Serial.print("Fall Detected: ");   Serial.println(fall_detected);
  Serial.print("Obstacle Alert: ");  Serial.println(obstacle_alert);
  Serial.print("Emergency Alert: "); Serial.println(emergency_alert);
  Serial.print("Heat Alert: ");      Serial.println(heat_alert);
  Serial.print("Amb Temp: ");        Serial.println(ambientTemp);
  Serial.print("Obj Temp: ");        Serial.println(objectTemp);
  Serial.print("Accel Mag: ");       Serial.println(accMagnitude);
  Serial.print("Deviation: ");       Serial.println(deviation);
  Serial.print("Priority: ");        Serial.println(priority);

  // -------- WIFI STATUS CHECK --------
  Serial.print("[DEBUG] WiFi status: ");
  Serial.println(WiFi.status());
  Serial.print("[DEBUG] Free heap: ");
  Serial.println(ESP.getFreeHeap());
  Serial.print("[DEBUG] Millis: ");
  Serial.println(millis());

  // -------- BUILD PAYLOAD --------
  String payload = "{";
  payload += "\"device_id\":\"" + device_id + "\",";
  payload += "\"distance\":" + String(distance, 2) + ",";
  payload += "\"floor_baseline\":" + String(floorBaseline, 2) + ",";
  payload += "\"floor_delta\":" + String(floorDelta, 2) + ",";
  payload += "\"approach_rate\":" + String(approachRate, 2) + ",";
  payload += "\"ambient_temp\":" + String(ambientTemp, 2) + ",";
  payload += "\"object_temp\":" + String(objectTemp, 2) + ",";
  payload += "\"heat_alert\":" + String(heat_alert ? "true" : "false") + ",";
  payload += "\"ax\":" + String(ax, 3) + ",";
  payload += "\"ay\":" + String(ay, 3) + ",";
  payload += "\"az\":" + String(az, 3) + ",";
  payload += "\"acc_magnitude\":" + String(accMagnitude, 3) + ",";
  payload += "\"fall_risk\":" + String(fall_risk ? "true" : "false") + ",";
  payload += "\"fall_detected\":" + String(fall_detected ? "true" : "false") + ",";
  payload += "\"drop_ahead_alert\":" + String(drop_ahead_alert ? "true" : "false") + ",";
  payload += "\"obstacle_alert\":" + String(obstacle_alert ? "true" : "false") + ",";
  payload += "\"emergency_alert\":" + String(emergency_alert ? "true" : "false") + ",";
  payload += "\"floor_status\":\"" + String(drop_ahead_alert ? "drop_suspected" : "normal") + "\",";
  payload += "\"notify_caregiver\":" + String(fall_detected ? "true" : "false") + ",";
  payload += "\"priority\":\"" + priority + "\"";
  payload += "}";

  Serial.print("[DEBUG] Payload: ");
  Serial.println(payload);

  // -------- HTTP POST --------
  Serial.println("\n[HTTP] Sending sensor data...");

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[ERROR] WiFi not connected");
    return;
  }

  Serial.print("[HTTP] URL: ");
  Serial.println(sensorURL);

  WiFiClient client;
  HTTPClient http;
  http.setTimeout(5000);

  http.begin(client, sensorURL);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("ngrok-skip-browser-warning", "true");

  Serial.print("[HTTP] Payload size: ");
  Serial.println(payload.length());

  int httpResponseCode = http.POST(payload);

  Serial.print("[HTTP] Response code: ");
  Serial.println(httpResponseCode);

  if (httpResponseCode > 0) {
    String response = http.getString();
    Serial.println("[HTTP] Response:");
    Serial.println(response);
  } else {
    Serial.print("[HTTP ERROR] ");
    Serial.println(http.errorToString(httpResponseCode));
  }

  http.end();

  // reset fall flag after successful send
  if (fall_detected) {
    fall_detected = false;
    Serial.println("[FALL] fall_detected reset after send");
  }
}

// ---------------- WIFI RESET CHECK ----------------
void checkWiFiReset() {
  if (digitalRead(WIFI_RESET_PIN) != LOW) return;
  unsigned long pressStart = millis();
  Serial.println("[WIFI] BOOT held — keep holding 3s to reset WiFi...");
  while (digitalRead(WIFI_RESET_PIN) == LOW) {
    if (millis() - pressStart >= WIFI_RESET_HOLD_MS) {
      Serial.println("[WIFI] Resetting WiFi credentials...");
      wm.resetSettings();
      Serial.println("[WIFI] Done — restarting into config portal...");
      delay(500);
      ESP.restart();
    }
    delay(50);
  }
  Serial.println("[WIFI] Released early — reset cancelled");
}

// ---------------- SETUP ----------------
void setup() {
  Serial.begin(115200);

  pinMode(WIFI_RESET_PIN, INPUT_PULLUP);
  wm.resetSettings();  // always clear saved WiFi on boot
  Serial.println("[WIFI] Credentials cleared — opening config portal...");

  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);

  Wire.begin(21, 22);

  mpu.initialize();
  Serial.println(mpu.testConnection() ? "[OK] MPU" : "[FAIL] MPU");
  Serial.println(mlx.begin() ? "[OK] MLX" : "[FAIL] MLX");

  if (!wm.autoConnect("ESP32-Assistive", "12345678")) {
    Serial.println("[ERROR] WiFi failed — restarting");
    ESP.restart();
  }

  Serial.println("[INFO] WiFi Connected");
  Serial.print("[DEBUG] IP Address: ");
  Serial.println(WiFi.localIP());
  Serial.print("[DEBUG] Signal (RSSI): ");
  Serial.println(WiFi.RSSI());
  Serial.print("[DEBUG] Sensor URL: ");
  Serial.println(sensorURL);

  // -------- STARTUP FLOOR CALIBRATION --------
  Serial.println("[CALIB] Calibrating floor baseline...");
  float sum = 0;
  for (int i = 0; i < 15; i++) {
    sum += getDistanceCM();
    delay(100);
  }

  floorBaseline = sum / 15;

  if (floorBaseline > 300 || floorBaseline == 999) {
    floorBaseline = 110;
    Serial.println("[CALIB] Bad baseline — using fallback 110cm");
  }

  baselineReady = true;
  Serial.print("[CALIB] Floor baseline = ");
  Serial.println(floorBaseline);
}

// ---------------- LOOP ----------------
void loop() {
  static unsigned long lastSample = 0;

  checkWiFiReset();  // hold BOOT 3s anytime to reset WiFi

  if (millis() - lastSample > 500) {
    sendSensorData();
    lastSample = millis();
  }
}
