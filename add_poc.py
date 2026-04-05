import csv
from pathlib import Path

TRACKER_DB = Path("/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-3.0/workflow_dashboard/data/migration_tracker_db.csv")

def add_row():
    existing = []
    headers = []
    
    if TRACKER_DB.exists():
        with open(TRACKER_DB, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            headers = reader.fieldnames or []
            existing = list(reader)
            
    # Add our new poc row
    new_row = {
        "customer_id": "PCO 001",
        "customer_name": "Dzoan architect",
        "env": "poc",
        "status": "In Progress",
        "target_region": "DFW3",
        "ospc_vms_count": "10",
        "ospc_volumes_count": "5",
        "ospc_db_count": "2",
        "flex_migrated_vms": "0",
        "flex_migrated_volumes": "0",
        "priority_rank": "1",
        "_prioScore": "1",
        "flex_readiness": "High",
        "industry": "Tech",
        "size_rank": "Small",
        "reference_architecture": "Standard 3-Tier"
    }
    
    # Update headers
    for k in new_row.keys():
        if k not in headers:
            headers.append(k)
            
    # Insert at the beginning or end? User said "add the first line"
    existing.insert(0, new_row)
    TRACKER_DB.parent.mkdir(exist_ok=True)
    with open(TRACKER_DB, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        writer.writeheader()
        writer.writerows(existing)

if __name__ == "__main__":
    add_row()
    print("Row added successfully.")
