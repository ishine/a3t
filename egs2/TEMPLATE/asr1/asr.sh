#!/bin/bash

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

log() {
    local fname=${BASH_SOURCE[1]##*/}
    echo -e "$(date '+%Y-%m-%dT%H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}
SECONDS=0

# General configuration
stage=1          # Processes starts from the specified stage.
stop_stage=10    # Processes is stopped at the specified stage.
ngpu=1           # The number of gpus ("0" uses cpu, otherwise use gpu).
nj=32            # The number of parallel jobs.
decode_nj=32     # The number of parallel jobs in decoding.
gpu_decode=false # Whether to perform gpu decoding.
dumpdir=dump     # Directory to dump features.
expdir=exp       # Directory to save experiments.

# Data preparation related
local_data_opts= # The options given to local/data.sh.

# Feature extraction related
feats_type=raw    # Feature type (raw or fbank_pitch).
audio_format=flac # Audio format (only in feats_type=raw).
fs=16k            # Sampling rate.

# Tokenization related
token_type=bpe      # Tokenization type (char or bpe).
nbpe=30             # The number of BPE vocabulary.
bpemode=unigram     # Mode of BPE (unigram or bpe).
oov="<unk>"         # Out of vocabrary symbol.
blank="<blank>"     # CTC blank symbol
sos_eos="<sos/eos>" # sos and eos symbole
bpe_input_sentence_size=100000000 # Size of input sentence for BPE.

# Language model related
use_lm=true       # Use language model for ASR decoding.
lm_tag=           # Suffix to the result dir for language model training.
lm_config=        # Config for language model training.
lm_args=          # Arguments for language model training, e.g., "--max_epoch 10".
                  # Note that it will overwrite args in lm config.
use_word_lm=false # Whether to use word language model.
# shellcheck disable=SC2034
word_vocab_size=10000 # Size of word vocabulary.

# ASR model related
asr_tag=    # Suffix to the result dir for asr model training.
asr_config= # Config for asr model training.
asr_args=   # Arguments for asr model training, e.g., "--max_epoch 10".
            # Note that it will overwrite args in asr config.
feats_normalize=global_mvn  # Normalizaton layer type

# Decoding related
decode_tag=    # Suffix to the result dir for decoding.
decode_config= # Config for decoding.
decode_args=   # Arguments for decoding, e.g., "--lm_weight 0.1".
               # Note that it will overwrite args in decode config.
decode_lm=eval.loss.best.pth       # Language modle path for decoding.
decode_asr_model=eval.acc.best.pth # ASR model path for decoding.
                                   # e.g.
                                   # decode_asr_model=train.loss.best.pth
                                   # decode_asr_model=3epoch/model.pth
                                   # decode_asr_model=eval.acc.best.pth
                                   # decode_asr_model=eval.loss.ave.pth

# [Task dependent] Set the datadir name created by local/data.sh
train_set=     # Name of training set.
dev_set=       # Name of development set.
eval_sets=     # Names of evaluation sets. Multiple items can be specified.
srctexts=      # Used for the training of BPE and the creation of a vocabulary list.
lm_train_text= # Text file path of language model training set.
lm_dev_text=   # Text file path of language model development set.
lm_test_text=  # Text file path of language model evaluation set.
nlsyms_txt=none # Non-linguistic symbol list if existing.

help_message=$(cat << EOF
Usage: $0 --train-set <train_set_name> --dev-set <dev_set_name> --eval_sets <eval_set_names> --srctexts <srctexts >

Options:
    # General configuration
    --stage      # Processes starts from the specified stage (default="${stage}").
    --stop_stage # Processes is stopped at the specified stage (default="${stop_stage}").
    --ngpu       # The number of gpus ("0" uses cpu, otherwise use gpu, default="${ngpu}").
    --nj         # The number of parallel jobs (default="${nj}").
    --decode_nj  # The number of parallel jobs in decoding (default="${decode_nj}").
    --gpu_decode # Whether to perform gpu decoding (default="${gpu_decode}").
    --dumpdir    # Directory to dump features (default="${dumpdir}").
    --expdir     # Directory to save experiments (default="${expdir}").

    # Data preparation related
    --local_data_opts # The options given to local/data.sh (default="${local_data_opts}").

    # Feature extraction related
    --feats_type   # Feature type (raw or fbank_pitch, default="${feats_type}").
    --audio_format # Audio format (only in feats_type=raw, default="${audio_format}").
    --fs           # Sampling rate (default="${fs}").

    # Tokenization related
    --token_type              # Tokenization type (char or bpe, default="${token_type}").
    --nbpe                    # The number of BPE vocabulary (default="${nbpe}").
    --bpemode                 # Mode of BPE (unigram or bpe, default="${bpemode}").
    --oov                     # Out of vocabrary symbol (default="${oov}").
    --blank                   # CTC blank symbol (default="${blank}").
    --sos_eos=                # sos and eos symbole (default="${sos_eos}").
    --bpe_input_sentence_size # Size of input sentence for BPE (default="${bpe_input_sentence_size}").

    # Language model related
    --lm_tag          # Suffix to the result dir for language model training (default="${lm_tag}").
    --lm_config       # Config for language model training (default="${lm_config}").
    --lm_args         # Arguments for language model training, e.g., "--max_epoch 10" (default="${lm_args}").
                      # Note that it will overwrite args in lm config.
    --use_word_lm     # Whether to use word language model (default="${use_word_lm}").
    --word_vocab_size # Size of word vocabulary (default="${word_vocab_size}").

    # ASR model related
    --asr_tag    # Suffix to the result dir for asr model training (default="${asr_tag}").
    --asr_config # Config for asr model training (default="${asr_config}").
    --asr_args   # Arguments for asr model training, e.g., "--max_epoch 10" (default="${asr_args}").
                 # Note that it will overwrite args in asr config.
    --feats_normalize # Normalizaton layer type (default="${feats_normalize}").

    # Decoding related
    --decode_tag       # Suffix to the result dir for decoding (default="${decode_tag}").
    --decode_config    # Config for decoding (default="${decode_config}").
    --decode_args      # Arguments for decoding, e.g., "--lm_weight 0.1" (default="${decode_args}").
                       # Note that it will overwrite args in decode config.
    --decode_lm        # Language modle path for decoding (default="${decode_lm}").
    --decode_asr_model # ASR model path for decoding (default="${decode_asr_model}").

    # [Task dependent] Set the datadir name created by local/data.sh
    --train_set     # Name of training set (required).
    --dev_set       # Name of development set (required).
    --eval_sets     # Names of evaluation sets (required).
    --srctexts      # Used for the training of BPE and the creation of a vocabulary list (required).
    --lm_train_text # Text file path of language model training set (default="${lm_train_text}").
    --lm_dev_text   # Text file path of language model development set (default="${lm_dev_text}").
    --lm_test_text  # Text file path of language model evaluation set (default="${lm_test_text}").
    --nlsyms_txt    # Non-linguistic symbol list if existing (default="${nlsyms_txt}").
EOF
)

log "$0 $*"
. utils/parse_options.sh

if [ $# -ne 0 ]; then
    log "${help_message}"
    log "Error: No positional arguments are required."
    exit 2
fi

. ./path.sh
. ./cmd.sh


# Check required arguments
[ -z "${train_set}" ] && { log "${help_message}"; log "Error: --train_set is required"; exit 2; };
[ -z "${dev_set}" ] &&   { log "${help_message}"; log "Error: --dev_set is required"  ; exit 2; };
[ -z "${eval_sets}" ] && { log "${help_message}"; log "Error: --eval_sets is required"; exit 2; };
[ -z "${srctexts}" ] &&  { log "${help_message}"; log "Error: --srctexts is required" ; exit 2; };
# Use the same text as ASR for lm training if not specified.
[ -z "${lm_train_text}" ] && lm_train_text="data/${train_set}/text"
[ -z "${lm_dev_text}" ] && lm_dev_text="data/${dev_set}/text"
# Use the text of the 1st evaldir if lm_test is not specified
[ -z "${lm_test_text}" ] && lm_test_text="data/${eval_sets%% *}/text"

# Check feature type
if [ "${feats_type}" = raw ]; then
    data_feats=${dumpdir}/raw
elif [ "${feats_type}" = fbank_pitch ]; then
    data_feats=${dumpdir}/fbank_pitch
elif [ "${feats_type}" = fbank ]; then
    data_feats=${dumpdir}/fbank
else
    log "${help_message}"
    log "Error: not supported: --feats_type ${feats_type}"
    exit 2
fi

# Check tokenization type
token_listdir=data/token_list
bpedir="${token_listdir}/bpe_${bpemode}${nbpe}"
bpeprefix="${bpedir}"/model
bpemodel="${bpeprefix}".model
bpetoken_list="${bpedir}"/tokens.txt
chartoken_list="${token_listdir}"/char/tokens.txt
# NOTE: keep for future development.
# shellcheck disable=SC2034
wordtoken_list="${token_listdir}"/word/tokens.txt

if [ "${token_type}" = bpe ]; then
    token_list="${bpetoken_list}"
elif [ "${token_type}" = char ]; then
    token_list="${chartoken_list}"
    bpemodel=""
else
    log "Error: not supported --token_type '${token_type}'"
    exit 2
fi
if ${use_word_lm}; then
    lm_token_list="${wordtoken_list}"
    lm_token_type=word
else
    lm_token_list="${token_list}"
    lm_token_type="${token_type}"
fi


# Set tag for naming of model directory
if [ -z "${asr_tag}" ]; then
    if [ -n "${asr_config}" ]; then
        asr_tag="$(basename "${asr_config}" .yaml)_${feats_type}_${token_type}"
    else
        asr_tag="train_${feats_type}_${token_type}"
    fi
    # Add overwritten arg's info
    if [ -n "${asr_args}" ]; then
        asr_tag+="$(echo "${asr_args}" | sed -e "s/--/\_/g" -e "s/[ |=]//g")"
    fi
fi
if [ -z "${lm_tag}" ]; then
    if [ -n "${lm_config}" ]; then
        lm_tag="$(basename "${lm_config}" .yaml)_${lm_token_type}"
    else
        lm_tag="train_${lm_token_type}"
    fi
    # Add overwritten arg's info
    if [ -n "${lm_args}" ]; then
        lm_tag+="$(echo "${lm_args}" | sed -e "s/--/\_/g" -e "s/[ |=]//g")"
    fi
fi
if [ -z "${decode_tag}" ]; then
    if [ -n "${decode_config}" ]; then
        decode_tag="$(basename "${decode_config}" .yaml)"
    else
        decode_tag=decode
    fi
    # Add overwritten arg's info
    if [ -n "${decode_args}" ]; then
        decode_tag+="$(echo "${decode_args}" | sed -e "s/--/\_/g" -e "s/[ |=]//g")"
    fi
    if "${use_lm}"; then
        decode_tag+="_lm_$(echo "${decode_lm}" | sed -e "s/\//_/g" -e "s/\.[^.]*$//g")"
    fi
    decode_tag+="_asr_model_$(echo "${decode_asr_model}" | sed -e "s/\//_/g" -e "s/\.[^.]*$//g")"
fi

# The directory used for collect-stats mode
asr_stats_dir="${expdir}/asr_stats"
lm_stats_dir="${expdir}/lm_stats"
# The directory used for training commands
asr_exp="${expdir}/asr_${asr_tag}"
lm_exp="${expdir}/lm_${lm_tag}"

# ========================== Main stages start from here. ==========================

if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    log "Stage 1: Data preparation for data/${train_set}, data/${dev_set}, etc."
    # [Task dependent] Need to create data.sh for new corpus
    local/data.sh ${local_data_opts}
fi


if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    if [ "${feats_type}" = raw ]; then
        log "Stage 2: Format wav.scp: data/ -> ${data_feats}/"

        # ====== Recreating "wav.scp" ======
        # Kaldi-wav.scp, which can describe the file path with unix-pipe, like "cat /some/path |",
        # shouldn't be used in training process.
        # "format_wav_scp.sh" dumps such pipe-style-wav to real audio file
        # and also it can also change the audio-format and sampling rate.
        # If nothing is need, then format_wav_scp.sh does nothing:
        # i.e. the input file format and rate is same as the output.

        for dset in "${train_set}" "${dev_set}" ${eval_sets}; do
            utils/copy_data_dir.sh data/"${dset}" "${data_feats}/${dset}"
            scripts/audio/format_wav_scp.sh --nj "${nj}" --cmd "${train_cmd}" \
                --audio-format "${audio_format}" --fs "${fs}" \
                "data/${dset}/wav.scp" "${data_feats}/${dset}"

            echo "${feats_type}" > "${data_feats}/${dset}/feats_type"
        done
        # FIXME(kamo): How can we get the global mean-variance if using on-the-fly scheme? I don't have clear way.

    elif [ "${feats_type}" = fbank_pitch ]; then
        log "[Require Kaldi] stage 2: ${feats_type} extract: data/ -> ${data_feats}/"

        for dset in "${train_set}" "${dev_set}" ${eval_sets}; do
            # 1. Copy datadir
            utils/copy_data_dir.sh data/"${dset}" "${data_feats}/${dset}"

            # 2. Feature extract
            _nj=$((nj<$(<"${data_feats}/${dset}/utt2spk" wc -l)?nj:$(<"${data_feats}/${dset}/utt2spk" wc -l)))
            steps/make_fbank_pitch.sh --nj "${_nj}" --cmd "${train_cmd}" "${data_feats}/${dset}"

            # 3. Derive the feature dimension
            pyscripts/feats/feat-to-shape.py "scp:head -n 1 ${data_feats}/${dset}/feats.scp |" - | \
                awk '{ print $2 }' | cut -d, -f2 > ${data_feats}/${dset}/feats_dim
            echo "${feats_type}" > "${data_feats}/${dset}/feats_type"
        done

    elif [ "${feats_type}" = fbank ]; then
        log "Stage 2: ${feats_type} extract: data/ -> ${data_feats}/"
        log "${feats_type} is not supported yet."
        exit 1

    else
        log "Error: not supported: --feats_type ${feats_type}"
        exit 2
    fi
fi


if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
    if [ "${token_type}" = bpe ]; then
        log "Stage 3: Generate token_list from ${srctexts} using BPE"

        mkdir -p "${bpedir}"
        # shellcheck disable=SC2002
        cat ${srctexts} | cut -f 2- -d" "  > "${bpedir}"/train.txt

        spm_train \
            --input="${bpedir}"/train.txt \
            --vocab_size="${nbpe}" \
            --model_type="${bpemode}" \
            --model_prefix="${bpeprefix}" \
            --input_sentence_size="${bpe_input_sentence_size}"

        _opts="--bpemodel ${bpemodel}"

    elif [ "${token_type}" = char ]; then
        log "Stage 3: Generate character level token_list from ${srctexts}"
        _opts="--non_linguistic_symbols ${nlsyms_txt}"

    else
        log "Error: not supported --token_type '${token_type}'"
        exit 2
    fi

    mkdir -p "$(dirname ${token_list})"

    # The first symbol in token_list must be "<blank>" and the last must be also sos/eos:
    # 0 is reserved for CTC-blank for ASR and also used as ignore-index in the other task

    # shellcheck disable=SC2002
    cat ${srctexts} | \
        python3 -m espnet2.bin.tokenize_text  \
            --token_type "${token_type}" -f 2- --input - --output - ${_opts} \
            --field 2- \
            --write_vocabulary true \
            --add_symbol "${blank}:0" \
            --add_symbol "${oov}:1" \
            --add_symbol "${sos_eos}:-1" \
        > "${token_list}"


    # Create word-list for word-LM training
    if ${use_word_lm}; then
        log "Generate word level token_list from ${srctexts}"
        mkdir -p "$(dirname ${lm_token_list})"
        # shellcheck disable=SC2002
        cat ${srctexts} |
            python3 -m espnet2.bin.tokenize_text \
                --token_type word -f 2- --input - --output - \
                --field 2- \
                --write_vocabulary true \
                --vocabrary_size "${word_vocab_size}" \
                --add_symbol "${blank}:0" \
                --add_symbol "${oov}:1" \
                --add_symbol "${sos_eos}:-1" \
            > "${lm_token_list}"
    fi

fi


# ========================== Data preparation is done here. ==========================


if "${use_lm}"; then
  if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
      log "Stage 4: LM collect stats: train_set=${lm_train_text}, dev_set=${lm_dev_text}"

      _opts=
      if [ -n "${lm_config}" ]; then
          # To generate the config file: e.g.
          #   % python3 -m espnet2.bin.lm_train --print_config --optim adam
          _opts+="--config ${lm_config} "
      fi

      # 1. Split the key file
      _logdir="${lm_stats_dir}/logdir"
      mkdir -p "${_logdir}"
      key_file="${lm_train_text}"
      split_scps=""
      _nj=$((decode_nj<$(<${key_file} wc -l)?decode_nj:$(<${key_file} wc -l)))
      for n in $(seq ${_nj}); do
          split_scps+=" ${_logdir}/train.${n}.scp"
      done
      # shellcheck disable=SC2086
      utils/split_scp.pl "${key_file}" ${split_scps}

      key_file="${lm_dev_text}"
      split_scps=""
      _nj=$((decode_nj<$(<${key_file} wc -l)?decode_nj:$(<${key_file} wc -l)))
      for n in $(seq ${_nj}); do
          split_scps+=" ${_logdir}/dev.${n}.scp"
      done
      # shellcheck disable=SC2086
      utils/split_scp.pl "${key_file}" ${split_scps}

      # 2. Submit jobs
      log "LM collect-stats started... log: '${lm_exp}/train.log'"
      # NOTE: --*_shape_file doesn't require length information if --batch_type=const --sort_in_batch=none
      # shellcheck disable=SC2086
      ${train_cmd} JOB=1:"${_nj}" "${_logdir}"/stats.JOB.log \
          python3 -m espnet2.bin.lm_train \
              --collect_stats true \
              --use_preprocessor true \
              --bpemodel "${bpemodel}" \
              --token_type "${lm_token_type}"\
              --token_list "${lm_token_list}" \
              --non_linguistic_symbols "${nlsyms_txt}" \
              --train_data_path_and_name_and_type "${lm_train_text},text,text" \
              --eval_data_path_and_name_and_type "${lm_dev_text},text,text" \
              --batch_type const \
              --sort_in_batch none \
              --train_shape_file "${_logdir}/train.JOB.scp" \
              --eval_shape_file "${_logdir}/dev.JOB.scp" \
              --output_dir "${_logdir}/stats.JOB" \
              ${_opts} ${lm_args}

      # 3. Aggregate shape files
      _opts=
      for i in $(seq "${_nj}"); do
          _opts+="--input_dir ${_logdir}/stats.${i} "
      done
      # shellcheck disable=SC2086
      python3 -m espnet2.bin.aggregate_stats_dirs ${_opts} --output_dir "${lm_stats_dir}"
  fi


  if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
      log "Stage 5: LM Training: train_set=${lm_train_text}, dev_set=${lm_dev_text}"

      _opts=
      if [ -n "${lm_config}" ]; then
          # To generate the config file: e.g.
          #   % python3 -m espnet2.bin.lm_train --print_config --optim adam
          _opts+="--config ${lm_config} "
      fi

      log "LM training started... log: '${lm_exp}/train.log'"
      # shellcheck disable=SC2086
      ${cuda_cmd} --gpu "${ngpu}" "${lm_exp}"/train.log \
          python3 -m espnet2.bin.lm_train \
              --ngpu "${ngpu}" \
              --use_preprocessor true \
              --bpemodel "${bpemodel}" \
              --token_type "${lm_token_type}"\
              --token_list "${lm_token_list}" \
              --non_linguistic_symbols "${nlsyms_txt}" \
              --train_data_path_and_name_and_type "${lm_train_text},text,text" \
              --eval_data_path_and_name_and_type "${lm_dev_text},text,text" \
              --train_shape_file "${lm_stats_dir}/train/text_shape" \
              --eval_shape_file "${lm_stats_dir}/eval/text_shape" \
              --max_length 150 \
              --resume true \
              --output_dir "${lm_exp}" \
              ${_opts} ${lm_args}

  fi


  if [ ${stage} -le 6 ] && [ ${stop_stage} -ge 6 ]; then
      log "Stage 6: Calc perplexity: ${lm_test_text}"
      _opts=
      # TODO(kamo): Parallelize?
      log "Perplexity calculation started... log: '${lm_exp}/perplexity_test/lm_calc_perplexity.log'"
      # shellcheck disable=SC2086
      ${cuda_cmd} --gpu "${ngpu}" "${lm_exp}"/perplexity_test/lm_calc_perplexity.log \
          python3 -m espnet2.bin.lm_calc_perplexity \
              --ngpu "${ngpu}" \
              --data_path_and_name_and_type "${lm_test_text},text,text" \
              --train_config "${lm_exp}"/config.yaml \
              --model_file "${lm_exp}/${decode_lm}" \
              --output_dir "${lm_exp}/perplexity_test" \
              ${_opts}
      log "PPL: ${lm_test_text}: $(cat ${lm_exp}/perplexity_test/ppl)"

  fi

else
    log "Stage 4-6: Skip lm-related stages: use_lm=${use_lm}"
fi


if [ ${stage} -le 7 ] && [ ${stop_stage} -ge 7 ]; then
    _asr_train_dir="${data_feats}/${train_set}"
    _asr_dev_dir="${data_feats}/${dev_set}"
    log "Stage 7: ASR collect stats: train_set=${_asr_train_dir}, dev_set=${_asr_dev_dir}"

    _opts=
    if [ -n "${asr_config}" ]; then
        # To generate the config file: e.g.
        #   % python3 -m espnet2.bin.asr_train --print_config --optim adam
        _opts+="--config ${asr_config} "
    fi

    _feats_type="$(<${_asr_train_dir}/feats_type)"
    if [ "${_feats_type}" = raw ]; then
        _scp=wav.scp
        # "sound" supports "wav", "flac", etc.
        _type=sound
        _opts+="--frontend_conf fs=${fs} "
    else
        _scp=feats.scp
        _type=kaldi_ark
        _input_size="$(<${_asr_train_dir}/feats_dim)"
        _opts+="--input_size=${_input_size} "
    fi

    # 1. Split the key file
    _logdir="${asr_stats_dir}/logdir"
    mkdir -p "${_logdir}"

    key_file="${_asr_train_dir}/${_scp}"
    split_scps=""
    _nj=$((decode_nj<$(<${key_file} wc -l)?decode_nj:$(<${key_file} wc -l)))
    for n in $(seq ${_nj}); do
        split_scps+=" ${_logdir}/train.${n}.scp"
    done
    # shellcheck disable=SC2086
    utils/split_scp.pl "${key_file}" ${split_scps}

    key_file="${_asr_dev_dir}/${_scp}"
    split_scps=""
    _nj=$((decode_nj<$(<${key_file} wc -l)?decode_nj:$(<${key_file} wc -l)))
    for n in $(seq ${_nj}); do
        split_scps+=" ${_logdir}/dev.${n}.scp"
    done
    # shellcheck disable=SC2086
    utils/split_scp.pl "${key_file}" ${split_scps}

    # FIXME(kamo): max_length is confusing name. How about fold_length?

    # 2. Submit jobs
    log "ASR collect-stats started... log: '${asr_exp}/train.log'"

    # NOTE: --*_shape_file doesn't require length information if --batch_type=const --sort_in_batch=none

    # shellcheck disable=SC2086
    ${train_cmd} JOB=1:"${_nj}" "${_logdir}"/stats.JOB.log \
        python3 -m espnet2.bin.asr_train \
            --collect_stats true \
            --use_preprocessor true \
            --bpemodel "${bpemodel}" \
            --token_type "${token_type}" \
            --token_list "${token_list}" \
            --non_linguistic_symbols "${nlsyms_txt}" \
            --batch_type const \
            --sort_in_batch none \
            --train_data_path_and_name_and_type "${_asr_train_dir}/${_scp},speech,${_type}" \
            --train_data_path_and_name_and_type "${_asr_train_dir}/text,text,text" \
            --eval_data_path_and_name_and_type "${_asr_dev_dir}/${_scp},speech,${_type}" \
            --eval_data_path_and_name_and_type "${_asr_dev_dir}/text,text,text" \
            --train_shape_file "${_logdir}/train.JOB.scp" \
            --eval_shape_file "${_logdir}/dev.JOB.scp" \
            --output_dir "${_logdir}/stats.JOB" \
            ${_opts} ${asr_args}

    # 3. Aggregate shape files
    _opts=
    for i in $(seq "${_nj}"); do
        _opts+="--input_dir ${_logdir}/stats.${i} "
    done
    # shellcheck disable=SC2086
    python3 -m espnet2.bin.aggregate_stats_dirs ${_opts} --output_dir "${asr_stats_dir}"
fi


if [ ${stage} -le 8 ] && [ ${stop_stage} -ge 8 ]; then
    _asr_train_dir="${data_feats}/${train_set}"
    _asr_dev_dir="${data_feats}/${dev_set}"
    log "Stage 8: ASR Training: train_set=${_asr_train_dir}, dev_set=${_asr_dev_dir}"

    _opts=
    if [ -n "${asr_config}" ]; then
        # To generate the config file: e.g.
        #   % python3 -m espnet2.bin.asr_train --print_config --optim adam
        _opts+="--config ${asr_config} "
    fi

    _feats_type="$(<${_asr_train_dir}/feats_type)"
    if [ "${_feats_type}" = raw ]; then
        _scp=wav.scp
        # "sound" supports "wav", "flac", etc.
        _type=sound
        _max_length=80000
        _opts+="--frontend_conf fs=${fs} "
    else
        _scp=feats.scp
        _type=kaldi_ark
        _max_length=800
        _input_size="$(<${_asr_train_dir}/feats_dim)"
        _opts+="--input_size=${_input_size} "

    fi
    if [ "${feats_normalize}" = global_mvn ]; then
        # Default normalization is utterance_mvn and changes to global_mvn
        _opts+="--normalize=global_mvn --normalize_conf stats_file=${asr_stats_dir}/train/feats_stats.npz"
    fi

    # FIXME(kamo): max_length is confusing name. How about fold_length?

    log "ASR training started... log: '${asr_exp}/train.log'"
    # shellcheck disable=SC2086
    ${cuda_cmd} --gpu "${ngpu}" "${asr_exp}"/train.log \
        python3 -m espnet2.bin.asr_train \
            --ngpu "${ngpu}" \
            --use_preprocessor true \
            --bpemodel "${bpemodel}" \
            --token_type "${token_type}" \
            --token_list "${token_list}" \
            --non_linguistic_symbols "${nlsyms_txt}" \
            --train_data_path_and_name_and_type "${_asr_train_dir}/${_scp},speech,${_type}" \
            --train_data_path_and_name_and_type "${_asr_train_dir}/text,text,text" \
            --eval_data_path_and_name_and_type "${_asr_dev_dir}/${_scp},speech,${_type}" \
            --eval_data_path_and_name_and_type "${_asr_dev_dir}/text,text,text" \
            --train_shape_file "${asr_stats_dir}/train/speech_shape" \
            --train_shape_file "${asr_stats_dir}/train/text_shape" \
            --eval_shape_file "${asr_stats_dir}/eval/speech_shape" \
            --eval_shape_file "${asr_stats_dir}/eval/text_shape" \
            --resume true \
            --max_length "${_max_length}" \
            --max_length 150 \
            --output_dir "${asr_exp}" \
            ${_opts} ${asr_args}

fi


if [ ${stage} -le 9 ] && [ ${stop_stage} -ge 9 ]; then
    log "Stage 9: Decoding: training_dir=${asr_exp}"

    if ${gpu_decode}; then
        _cmd=${cuda_cmd}
        _ngpu=1
    else
        _cmd=${decode_cmd}
        _ngpu=0
    fi

    _opts=
    if [ -n "${decode_config}" ]; then
        _opts+="--config ${decode_config} "
    fi
    if "${use_lm}"; then
        _opts+="--lm_train_config ${lm_exp}/config.yaml "
        _opts+="--lm_file ${lm_exp}/${decode_lm} "
    fi

    for dset in "${dev_set}" ${eval_sets}; do
        _data="${data_feats}/${dset}"
        _dir="${asr_exp}/decode_${dset}${decode_tag}"
        _logdir="${_dir}/logdir"
        mkdir -p "${_logdir}"

        _feats_type="$(<${_data}/feats_type)"
        if [ "${_feats_type}" = raw ]; then
            _scp=wav.scp
            _type=sound
        else
            _scp=feats.scp
            _type=kaldi_ark
        fi

        # 1. Split the key file
        key_file=${_data}/${_scp}
        split_scps=""
        _nj=$((decode_nj<$(<${key_file} wc -l)?decode_nj:$(<${key_file} wc -l)))
        for n in $(seq ${_nj}); do
            split_scps+=" ${_logdir}/keys.${n}.scp"
        done
        # shellcheck disable=SC2086
        utils/split_scp.pl "${key_file}" ${split_scps}

        # 2. Submit decoding jobs
        log "Decoding started... log: '${_logdir}/asr_recog.*.log'"
        # shellcheck disable=SC2086
        ${_cmd} --gpu "${_ngpu}" JOB=1:"${_nj}" "${_logdir}"/asr_recog.JOB.log \
            python3 -m espnet2.bin.asr_decode \
                --ngpu "${_ngpu}" \
                --data_path_and_name_and_type "${_data}/${_scp},speech,${_type}" \
                --key_file "${_logdir}"/keys.JOB.scp \
                --asr_train_config "${asr_exp}"/config.yaml \
                --asr_model_file "${asr_exp}"/"${decode_asr_model}" \
                --output_dir "${_logdir}"/output.JOB \
                ${_opts} ${decode_args}

        # 3. Concatenates the output files from each jobs
        for f in token token_int score text; do
            for i in $(seq "${_nj}"); do
                cat "${_logdir}/output.${i}/1best_recog/${f}"
            done | LC_ALL=C sort -k1 >"${_dir}/${f}"
        done
    done
fi


if [ ${stage} -le 10 ] && [ ${stop_stage} -ge 10 ]; then
    log "Stage 10: Scoring"

    for dset in "${dev_set}" ${eval_sets}; do
        _data="${data_feats}/${dset}"
        _dir="${asr_exp}/decode_${dset}${decode_tag}"

        for _type in cer wer ter; do
            [ "${_type}" = ter ] && [ ! -f "${bpemodel}" ] && continue

            _scoredir="${_dir}/score_${_type}"
            mkdir -p "${_scoredir}"

            if [ "${_type}" = wer ]; then
                # Covert text to "trn" format
                <"${_data}/text" \
                    awk ' { s=""; for(i=2;i<=NF;++i){ s=s $i " "; }; print s "(" $1 ")"; } ' \
                        >"${_scoredir}/ref.trn"
                <"${_dir}/text" \
                    awk ' { s=""; for(i=2;i<=NF;++i){ s=s $i " "; }; print s "(" $1 ")"; } ' \
                        >"${_scoredir}/hyp.trn"

            elif [ "${_type}" = cer ]; then
                # Tokenize text to char level
                paste \
                    <(<"${_data}/text" \
                          python3 -m espnet2.bin.tokenize_text  \
                              -f 2- --input - --output - \
                              --token_type char \
                              --non_linguistic_symbols "${nlsyms_txt}" \
                              --remove_non_linguistic_symbols true) \
                    <(<"${_data}/text" awk '{ print "(" $1 ")" }') \
                        >"${_scoredir}/ref.trn"

                paste \
                    <(<"${_dir}/text"  \
                          python3 -m espnet2.bin.tokenize_text  \
                              -f 2- --input - --output - \
                              --token_type char \
                              --non_linguistic_symbols "${nlsyms_txt}" \
                              --remove_non_linguistic_symbols true) \
                    <(<"${_data}/text" awk '{ print "(" $1 ")" }') \
                        >"${_scoredir}/hyp.trn"

            elif [ "${_type}" = ter ]; then
                # Tokenize text using BPE
                paste \
                    <(<"${_data}/text" \
                          python3 -m espnet2.bin.tokenize_text  \
                              -f 2- --input - --output - \
                              --token_type bpe \
                              --bpemodel "${bpemodel}") \
                    <(<"${_data}/text" awk '{ print "(" $1 ")" }') \
                        >"${_scoredir}/ref.trn"

                paste \
                    <(<"${_dir}/text" \
                          python3 -m espnet2.bin.tokenize_text  \
                              -f 2- --input - --output - \
                              --token_type bpe \
                              --bpemodel "${bpemodel}") \
                    <(<"${_data}/text" awk '{ print "(" $1 ")" }') \
                        >"${_scoredir}/hyp.trn"
            fi

            sclite \
                -r "${_scoredir}/ref.trn" trn \
                -h "${_scoredir}/hyp.trn" trn \
                -i rm -o all stdout > "${_scoredir}/result.txt"

            log "Write ${_type} result in ${_scoredir}/result.txt"
            grep -e Avg -e SPKR -m 2 "${_scoredir}/result.txt"
        done

    done

    # Show results in Markdown syntax
    scripts/utils/show_asr_result.sh "${asr_exp}" > "${asr_exp}"/RESULTS.md
    cat "${asr_exp}"/RESULTS.md

fi


if [ ${stage} -le 11 ] && [ ${stop_stage} -ge 11 ]; then
    log "[Option] Stage 11: Pack model: ${asr_exp}/packed.tgz"

    _opts=
    if "${use_lm}"; then
        _opts+="--lm_train_config.yaml ${lm_exp}/config.yaml "
        _opts+="--lm_file.pth ${lm_exp}/${decode_lm} " 
    fi
    if [ "${feats_normalize}" = global_mvn ]; then
        _opts+="--option ${asr_stats_dir}/train/feats_stats.npz "
    fi
    if [ "${token_type}" = bpe ]; then
        _opts+="--option ${bpemodel} "
    fi
    # shellcheck disable=SC2086
    python -m espnet2.bin.pack asr \
        --asr_train_config.yaml "${asr_exp}"/config.yaml \
        --asr_model_file.pth "${asr_exp}"/"${decode_asr_model}" \
        ${_opts} \
        --option "${asr_exp}"/RESULTS.md \
        --outpath "${asr_exp}/packed.tgz"

fi

log "Successfully finished. [elapsed=${SECONDS}s]"
