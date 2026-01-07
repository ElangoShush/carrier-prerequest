import argparse
from datetime import timedelta
from google.cloud import storage

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bucket", required=True)
    p.add_argument("--object", required=True, dest="object_name")
    p.add_argument("--minutes", type=int, default=120)
    p.add_argument("--content-type", default="text/plain")
    args = p.parse_args()

    client = storage.Client()
    bucket = client.bucket(args.bucket)
    blob = bucket.blob(args.object_name)

    url = blob.generate_signed_url(
        version="v4",
        expiration=timedelta(minutes=args.minutes),
        method="PUT",
        content_type=args.content_type,
    )
    print(url)

if __name__ == "__main__":
    main()
