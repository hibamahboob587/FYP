def decision_engine(detected_objects, sensor_distance):
    if "vehicle" in detected_objects:
        return "vehicle", "critical"

    if "dog" in detected_objects:
        return "dog", "high"

    if "stopsign" in detected_objects:
        return "stopsign", "high"

    if "trafficlight" in detected_objects:
        return "trafficlight", "medium"

    if "crosswalk" in detected_objects:
        return "crosswalk", "medium"

    if "stairs" in detected_objects:
        return "stairs", "medium"

    if "person" in detected_objects:
        return "person", "low"

    if "door" in detected_objects:
        return "door", "low"

    if "pole" in detected_objects:
        return "pole", "low"

    if "pothole" in detected_objects:
        return "pothole", "low"

    return "safe", "none"
