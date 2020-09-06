#!/bin/bash
# Copyright   2019   David Snyder
#             2020   Desh Raj

# Apache 2.0.
#
# This script takes an input directory that has a segments file (and
# a feats.scp file), and performs diarization on it, using BUTs
# Bayesian HMM-based diarization model. A first-pass of AHC is performed
# first followed by VB-HMM.

stage=0
nj=10
cmd="run.pl"
ref_rttm=
score_overlaps_only=true

echo "$0 $@"  # Print the command line for logging
if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;
if [ $# != 3 ]; then
  echo "Usage: $0 <model-dir> <in-data-dir> <out-dir>"
  echo "e.g.: $0 exp/xvector_nnet_1a  data/dev exp/dev_diarization"
  echo "Options: "
  echo "  --nj <nj>                                        # number of parallel jobs."
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --ref_rttm ./local/dev_rttm                      # the location of the reference RTTM file"
  exit 1;
fi

model_dir=$1
data_in=$2
out_dir=$3

name=`basename $data_in`

for f in $data_in/feats.scp $data_in/segments $model_dir/plda \
  $model_dir/final.raw $model_dir/extract.config; do
  [ ! -f $f ] && echo "$0: No such file $f" && exit 1;
done

if [ $stage -le 1 ]; then
  echo "$0: computing features for x-vector extractor"
  utils/fix_data_dir.sh data/${name}
  rm -rf data/${name}_cmn
  local/nnet3/xvector/prepare_feats.sh --nj $nj --cmd "$cmd" \
    data/$name data/${name}_cmn exp/${name}_cmn
  cp data/$name/segments exp/${name}_cmn/
  utils/fix_data_dir.sh data/${name}_cmn
fi

if [ $stage -le 2 ]; then
  echo "$0: extracting x-vectors for all segments"
  diarization/nnet3/xvector/extract_xvectors.sh --cmd "$cmd" \
    --nj $nj --window 1.5 --period 0.75 --apply-cmn false \
    --min-segment 0.5 $model_dir \
    data/${name}_cmn $out_dir/xvectors_${name}
fi

# Perform PLDA scoring
if [ $stage -le 3 ]; then
  # Perform PLDA scoring on all pairs of segments for each recording.
  echo "$0: performing PLDA scoring between all pairs of x-vectors"
  diarization/nnet3/xvector/score_plda.sh --cmd "$cmd" \
    --target-energy 0.5 \
    --nj $nj $model_dir/ $out_dir/xvectors_${name} \
    $out_dir/xvectors_${name}/plda_scores
fi

if [ $stage -le 4 ]; then
  echo "$0: performing clustering using PLDA scores (threshold tuned on dev)"
  diarization/cluster.sh --cmd "$cmd" --nj $nj \
    --rttm-channel 1 --threshold 0.4 \
    $out_dir/xvectors_${name}/plda_scores $out_dir
  echo "$0: wrote RTTM to output directory ${out_dir}"
fi

if [ $stage -le 5 ]; then
  echo "$0: performing VB-HMM on top of first-pass AHC"
  diarization/vb_hmm_xvector.sh --nj $nj --rttm-channel 1 \
    $out_dir $out_dir/xvectors_${name} $model_dir/plda
fi

hyp_rttm=${out_dir}/rttm

# For scoring the diarization system, we use the same tool that was
# used in the DIHARD II challenge. This is available at:
# https://github.com/nryant/dscore
if [ $stage -le 6 ]; then
  echo "Diarization results for "${name}
  if ! [ -d dscore ]; then
    git clone https://github.com/desh2608/dscore.git -b libricss --single-branch || exit 1;
    cd dscore
    pip install -r requirements.txt
    cd ..
  fi

  # Create per condition ref and hyp RTTM files for scoring per condition
  mkdir -p tmp
  conditions="0L 0S OV10 OV20 OV30 OV40"
  cp $ref_rttm tmp/ref.all
  cp $hyp_rttm tmp/hyp.all
  for rttm in ref hyp; do
    for cond in $conditions; do
      cat tmp/$rttm.all | grep $cond > tmp/$rttm.$cond
    done
  done

  echo "Scoring all regions..."
  for cond in $conditions 'all'; do
    echo -n "Condition: $cond: "
    ref_rttm_path=$(readlink -f tmp/ref.$cond)
    hyp_rttm_path=$(readlink -f tmp/hyp.$cond)
    cd dscore && python score.py -r $ref_rttm_path -s $hyp_rttm_path --global_only && cd .. || exit 1;
  done

  # We also score overlapping regions only
  if [ $score_overlaps_only == "true" ]; then
    echo "Scoring overlapping regions..."
    for cond in $conditions 'all'; do
      echo -n "Condition: $cond: "
      ref_rttm_path=$(readlink -f tmp/ref.$cond)
      hyp_rttm_path=$(readlink -f tmp/hyp.$cond)
      cd dscore && python score.py -r $ref_rttm_path -s $hyp_rttm_path --overlap_only --global_only && cd .. || exit 1;
    done
  fi

  rm -r tmp
fi
