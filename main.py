import re
from datetime import datetime, timezone
import firebase_admin
from firebase_admin import credentials, firestore
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# 1. Initialize FastAPI Application
app = FastAPI(
    title="Sime Darby Property Township Smart Gate API",
    description="Automated gate verification checking resident standing and time-bound guest access.",
    version="1.0.0"
)

# 2. Configure Cross-Origin Resource Sharing (CORS) for Flutter and Web Clients
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 3. Initialize Firebase Admin SDK
# Ensure 'serviceAccountKey.json' is saved in the same directory as main.py
cred = credentials.Certificate("serviceAccountKey.json")
firebase_admin.initialize_app(cred)
db = firestore.client()


# 4. Request Model for Raspberry Pi Gate Scan Triggers
class PlateScanRequest(BaseModel):
    scanned_plate: str  # Original camera OCR raw output (e.g., "WXY 1234")
    direction: str      # "IN" or "OUT"


# Helper: Normalize Malaysian License Plates
# Strips white spaces and forces uppercase (e.g., "vab 5678" -> "VAB5678")
def normalize_plate(plate: str) -> str:
    return re.sub(r'\s+', '', plate).upper()


# Helper: Save Access Records to Firestore
def log_access(plate: str, direction: str, success: bool, reason: str, unit: str):
    db.collection("gate_logs").add({
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "scanned_plate": plate,
        "direction": direction,
        "access_granted": success,
        "reason": reason,
        "host_unit": unit
    })


# Core Endpoint: Check Access and Control Barrier Action
@app.post("/api/gate/verify")
async def verify_gate_access(request: PlateScanRequest):
    raw_plate = request.scanned_plate
    clean_plate = normalize_plate(raw_plate)
    now = datetime.now(timezone.utc)
    
    print(f"==================================================")
    print(f"🔄 Processing Scan: {raw_plate} -> Normalized: {clean_plate} | Dir: {request.direction}")
    
    # --------------------------------------------------
    # CHECK 1: Resident Auto-Lane Verification
    # --------------------------------------------------
    residents_ref = db.collection("residents")
    resident_query = residents_ref.where("car_plate", "==", clean_plate).stream()
    
    resident_doc = None
    for doc in resident_query:
        resident_doc = doc
        break  # Match found
        
    if resident_doc:
        res_data = resident_doc.to_dict()
        unit_id = resident_doc.id
        
        # Behavior Nudge: Block gate if maintenance payment is overdue
        if res_data.get("maintenance_status") == "PAID":
            log_access(clean_plate, request.direction, True, "VALID_RESIDENT", unit_id)
            return {
                "access_granted": True,
                "role": "RESIDENT",
                "unit": unit_id,
                "message": f"Access Granted. Welcome home! Unit {unit_id}."
            }
        else:
            log_access(clean_plate, request.direction, False, "RESIDENT_OVERDUE", unit_id)
            return {
                "access_granted": False,
                "role": "RESIDENT",
                "unit": unit_id,
                "outstanding_balance": res_data.get("outstanding_balance", 0.0),
                "message": f"Access Denied. Unit {unit_id} has overdue maintenance fees. Please settle in-app to restore fast-track lane."
            }

    # --------------------------------------------------
    # CHECK 2: Visitor Pre-Booked Access Verification
    # --------------------------------------------------
    passes_ref = db.collection("visitor_passes")
    guest_query = (
        passes_ref.where("guest_plate", "==", clean_plate)
        .where("status", "==", "APPROVED")
        .stream()
    )
    
    for doc in guest_query:
        pass_data = doc.to_dict()
        pass_id = doc.id
        unit_id = pass_data.get("host_unit")
        
        # Convert Firestore UTC ISO strings to timezone-aware datetimes
        start_time = datetime.fromisoformat(pass_data.get("start_time").replace("Z", "+00:00"))
        end_time = datetime.fromisoformat(pass_data.get("end_time").replace("Z", "+00:00"))
        
        # Validate if current time falls within active timeframe
        is_active = (start_time <= now <= end_time)
        
        if is_active:
            # Important Safeguard: Restrict visitors if the host unit has overdue balance
            host_doc = db.collection("residents").document(unit_id).get()
            if host_doc.exists and host_doc.to_dict().get("maintenance_status") == "OVERDUE":
                log_access(clean_plate, request.direction, False, "HOST_OVERDUE", unit_id)
                return {
                    "access_granted": False,
                    "role": "GUEST",
                    "unit": unit_id,
                    "message": f"Access Denied. Host unit {unit_id} has outstanding maintenance accounts."
                }
            
            # Update Visitor Pass status to checked-in/out
            new_status = "CHECKED_IN" if request.direction == "IN" else "CHECKED_OUT"
            db.collection("visitor_passes").document(pass_id).update({"status": new_status})
            
            log_access(clean_plate, request.direction, True, "VALID_GUEST_PASS", unit_id)
            return {
                "access_granted": True,
                "role": "GUEST",
                "unit": unit_id,
                "message": f"Pass Verified. Welcome to Unit {unit_id}. Have a great visit!"
            }
        else:
            log_access(clean_plate, request.direction, False, "OUTSIDE_TIMEFRAME", unit_id)
            return {
                "access_granted": False,
                "role": "GUEST",
                "unit": unit_id,
                "message": "Access Denied. Current time is outside your pre-booked visitor pass timeframe."
            }

    # --------------------------------------------------
    # CHECK 3: Unregistered Vehicles
    # --------------------------------------------------
    log_access(clean_plate, request.direction, False, "UNKNOWN_VEHICLE", "N/A")
    return {
        "access_granted": False,
        "role": "UNKNOWN",
        "unit": "N/A",
        "message": "Access Denied. License plate unrecognized. Please register at the guardhouse."
    }
