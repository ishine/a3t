#!/usr/bin/env bash
#
# Copyright  2020  Johns Hopkins University (Author: Desh Raj)
# Apache 2.0

# Begin configuration section.
# End configuration section
. ./utils/parse_options.sh  # accept options

. ./path.sh

echo >&2 "$0" "$@"
if [ $# -ne 1 ] ; then
  echo >&2 "$0" "$@"
  echo >&2 "$0: Error: wrong number of arguments"
  echo -e >&2 "Usage:\n  $0 [opts] <corpus-dir>"
  echo -e >&2 "eg:\n  $0 /export/corpora/LibriCSS"
  exit 1
fi

corpus_dir=$1

set -e -o pipefail

# If data is not already present, then download and unzip
if [ ! -d $corpus_dir/for_release ]; then
    echo "Downloading and unpacking LibriCSS data."    
    CWD=`pwd`
    mkdir -p $corpus_dir

    cd $corpus_dir

    # Download the data. If the data has already been downloaded, it
    # does nothing. (See wget -c) 
    wget -c --load-cookies /tmp/cookies.txt \
      "https://docs.google.com/uc?export=download&confirm=$(wget --quiet \
      --save-cookies /tmp/cookies.txt --keep-session-cookies --no-check-certificate \
      'https://docs.google.com/uc?export=download&id=1Piioxd5G_85K9Bhcr8ebdhXx0CnaHy7l' \
      -O- | sed -rn 's/.*confirm=([0-9A-Za-z_]+).*/\1\n/p')&id=1Piioxd5G_85K9Bhcr8ebdhXx0CnaHy7l" \
      -O for_release.zip && rm -rf /tmp/cookies.txt

    # unzip (skip if already extracted)
    unzip -n for_release.zip

    # segmentation
    cd for_release
    python3 segment_libricss.py -data_path .

    cd $CWD
fi

# Process the downloaded data directory to get data in Kaldi format
mkdir -p data/local/data/
local/prepare_data.py --srcpath $corpus_dir/for_release --tgtpath data/local/data --mics 0

# Create dev and eval splits based on sessions. In total we have 10 sessions (session0 to 
# session9) of approximately 1 hour each. In the below strings, separate each session by
# '\|' to perform grep at once.
dev_sessions="session0"
eval_sessions="session1\|session2\|session3\|session4\|session5\|session6\|session7\|session8\|session9"

mkdir -p data/dev
for file in wav.scp utt2spk text segments; do
  grep $dev_sessions data/local/data/"$file" | sort > data/dev/"$file" 
done

mkdir -p data/eval
for file in wav.scp utt2spk text segments; do
  grep $eval_sessions data/local/data/"$file" | sort > data/eval/"$file" 
done

# Move the utt2spk, segments, and text file to .bak so that they are only used
# in the last scoring stage. We also prepare a dummy utt2spk and spk2utt for
# these.
for datadir in dev eval; do
  for file in text utt2spk segments; do
    mv data/$datadir/$file data/$datadir/$file.bak
  done

  awk '{print $1, $1}' data/$datadir/wav.scp > data/$datadir/utt2spk
  utils/utt2spk_to_spk2utt.pl data/$datadir/utt2spk > data/$datadir/spk2utt

done