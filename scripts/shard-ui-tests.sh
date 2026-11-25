#!/usr/bin/env bash
set -euo pipefail

# Splits UI test classes into shards by test count. Each shard takes a contiguous range of the
# name-sorted classes, balanced by test count. A class whose test midpoint lands exactly on a cut
# goes to the lower-numbered shard.
#
# Usage: shard-ui-tests.sh <shard> <total-shards> <class-list-file> <count-file>
#   <shard>: 0-based shard index
#   <total-shards>: total number of shards
#   <class-list-file>: file with one line per class, format: "ClassName TestCount"
#   <count-file>: file to write the shard's test count to
#
# Writes the shard's classes to stdout, one per line.
# Writes the shard's test count to <count-file>.
# Exits nonzero when the split is invalid or the shard is out of range.

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <shard> <total-shards> <class-list-file> <count-file>" >&2
  exit 1
fi

shard="$1"
total_shards="$2"
list_file="$3"
count_file="$4"

# Validate arguments.
if [[ -z "$shard" ]] || [[ -z "$total_shards" ]]; then
  echo "Error: shard and total-shards must not be empty" >&2
  exit 1
fi

if ! [[ "$shard" =~ ^[0-9]+$ ]] || ! [[ "$total_shards" =~ ^[0-9]+$ ]]; then
  echo "Error: shard and total-shards must be numbers" >&2
  exit 1
fi

if [[ "$shard" -lt 0 ]] || [[ "$shard" -ge "$total_shards" ]]; then
  echo "Error: shard $shard out of range 0..$((total_shards - 1))" >&2
  exit 1
fi

if [[ ! -f "$list_file" ]]; then
  echo "Error: class list file not found: $list_file" >&2
  exit 1
fi

# Run the split in awk. Sort by class name under LC_ALL=C, pipe directly into awk. The split
# computes the whole partition and fails unless every class lands in exactly one shard and the
# listing holds at least one test.
LC_ALL=C sort -k1,1 "$list_file" | LC_ALL=C awk -v shard="$shard" -v total_shards="$total_shards" -v count_file="$count_file" '
BEGIN {
  if (total_shards < 1) {
    print "Error: total_shards must be at least 1" >"/dev/stderr"
    exit 1
  }
}

{
  if (NF != 2) {
    print "Error: invalid line format, expected \"ClassName TestCount\": " $0 >"/dev/stderr"
    exit 1
  }
  class_name[NR] = $1
  test_count[NR] = $2
  if ($2 !~ /^[0-9]+$/ || $2 < 1) {
    print "Error: test count must be a positive integer: " $0 >"/dev/stderr"
    exit 1
  }
  total_tests += $2
  num_classes = NR
}

END {
  if (num_classes == 0) {
    print "Error: no classes in listing" >"/dev/stderr"
    exit 1
  }
  if (total_tests == 0) {
    print "Error: listing holds no tests" >"/dev/stderr"
    exit 1
  }

  # Compute the partition using integer arithmetic. Each class goes to the shard whose range holds
  # the midpoint of its tests in the running count. A midpoint that lands exactly on a cut goes to
  # the lower-numbered shard.
  #
  # Let m2 = 2 * running + count. That is twice the midpoint.
  # The shard is ceil(m2 * SHARDS / (2 * total)), clamped to at least 1, then converted to 0-based.
  # In integer arithmetic: floor((m2 * SHARDS + 2 * total - 1) / (2 * total)), then subtract 1.
  running_count = 0

  for (i = 1; i <= num_classes; i++) {
    m2 = 2 * running_count + test_count[i]
    target_shard_1based = int((m2 * total_shards + 2 * total_tests - 1) / (2 * total_tests))
    if (target_shard_1based < 1) target_shard_1based = 1
    target_shard = target_shard_1based - 1
    if (target_shard >= total_shards) target_shard = total_shards - 1

    class_shard[i] = target_shard
    running_count += test_count[i]
    shard_test_counts[target_shard] += test_count[i]
  }

  # Verify every class landed in exactly one shard.
  for (i = 1; i <= num_classes; i++) {
    if (class_shard[i] < 0 || class_shard[i] >= total_shards) {
      print "Error: class " class_name[i] " assigned to invalid shard " class_shard[i] >"/dev/stderr"
      exit 1
    }
  }

  # Verify partition coverage. Count how many classes each shard has.
  for (i = 1; i <= num_classes; i++) {
    shard_class_counts[class_shard[i]]++
  }
  coverage = 0
  for (s = 0; s < total_shards; s++) {
    coverage += shard_class_counts[s]
  }
  if (coverage != num_classes) {
    print "Error: partition covers " coverage " classes, expected " num_classes >"/dev/stderr"
    exit 1
  }

  # Print the requested shard'\''s classes in order.
  for (i = 1; i <= num_classes; i++) {
    if (class_shard[i] == shard) {
      print class_name[i]
    }
  }

  # Write the shard'\''s test count to the count file.
  print shard_test_counts[shard] >count_file
}
'
