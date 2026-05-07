import requests

REPO = "https://codeberg.org/lung/revo"

a = requests.post(f"{REPO}/releases")
