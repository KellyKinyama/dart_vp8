#!/bin/bash
# Download the remaining VP8 conformance vectors from WebM project storage.
# Files land in test/fixtures/ alongside the existing 18 comprehensive vectors.

set -e
cd "$(dirname "$0")/.."
mkdir -p test/fixtures
cd test/fixtures

URL="https://storage.googleapis.com/downloads.webmproject.org/test_data/libvpx"

VECTORS=(
  vp80-01-intra-1400 vp80-01-intra-1411 vp80-01-intra-1416 vp80-01-intra-1417
  vp80-02-inter-1402 vp80-02-inter-1412 vp80-02-inter-1418 vp80-02-inter-1424
  vp80-03-segmentation-01 vp80-03-segmentation-02
  vp80-03-segmentation-03 vp80-03-segmentation-04
  vp80-03-segmentation-1401 vp80-03-segmentation-1403
  vp80-03-segmentation-1407 vp80-03-segmentation-1408
  vp80-03-segmentation-1409 vp80-03-segmentation-1410
  vp80-03-segmentation-1413 vp80-03-segmentation-1414
  vp80-03-segmentation-1415 vp80-03-segmentation-1425
  vp80-03-segmentation-1426 vp80-03-segmentation-1427
  vp80-03-segmentation-1432 vp80-03-segmentation-1435
  vp80-03-segmentation-1436 vp80-03-segmentation-1437
  vp80-03-segmentation-1441 vp80-03-segmentation-1442
  vp80-04-partitions-1404 vp80-04-partitions-1405 vp80-04-partitions-1406
  vp80-05-sharpness-1428 vp80-05-sharpness-1429
  vp80-05-sharpness-1430 vp80-05-sharpness-1431
  vp80-05-sharpness-1433 vp80-05-sharpness-1434
  vp80-05-sharpness-1438 vp80-05-sharpness-1439
  vp80-05-sharpness-1440 vp80-05-sharpness-1443
  vp80-06-smallsize
)

for v in "${VECTORS[@]}"; do
  for ext in ivf ivf.md5; do
    f="$v.$ext"
    if [ -s "$f" ]; then continue; fi
    echo "GET $f"
    curl -fsSL "$URL/$f" -o "$f" || { echo "FAIL $f"; rm -f "$f"; }
  done
done

# Sample WebM clip used by test/webm_test.dart (Big Buck Bunny, ~1MB).
WEBM_URL="https://test-videos.co.uk/vids/bigbuckbunny/webm/vp8/360/Big_Buck_Bunny_360_10s_1MB.webm"
if [ ! -s sample.webm ]; then
  echo "GET sample.webm"
  curl -fsSL "$WEBM_URL" -o sample.webm || { echo "FAIL sample.webm"; rm -f sample.webm; }
fi
echo "done."
