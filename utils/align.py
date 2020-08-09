import numpy as np

import pyximport
pyximport.install(setup_args={"include_dirs":np.get_include()},build_dir="build", build_in_temp=False)

from alignSearch import cython_fill_table

import sys

import torch

sys.path.append("../../../espnet")
from espnet.asr.asr_utils import get_model_conf

import os
from pathlib import Path
from time import time

import argparse

parser = argparse.ArgumentParser()
parser.add_argument("model_path")
parser.add_argument("data_path")
parser.add_argument("eval_path")
parser.add_argument('--start_win', type=int, default=8000)
args = parser.parse_args()

max_prob = -10000000000.0

def align(lpz, char_list, ground_truth, utt_begin_indices, skip_prob):   
    blank = 0
    print("Audio length: " + str(lpz.shape[0]))
    print("Text length: " + str(len(ground_truth)))
    if len(ground_truth) > lpz.shape[0] and skip_prob <= max_prob:
        raise AssertionError("Audio is shorter than text!")
    window_len = args.start_win

    # Try multiple window lengths if it fails
    while True:
        # Create table which will contain alignment probabilities
        table = np.zeros([min(window_len, lpz.shape[0]), len(ground_truth)], dtype=np.float32)
        table.fill(max_prob)
        # Use array to log window offsets per character
        offsets = np.zeros([len(ground_truth)], dtype=np.int)

        # Run actual alignment
        t, c = cython_fill_table(table, lpz.astype(np.float32), np.array(ground_truth), offsets, np.array(utt_begin_indices), blank, skip_prob)

        print("Max prob: " + str(table[:, c].max()) + " at " + str(t))

        # Backtracking
        timings = np.zeros([len(ground_truth)])
        char_probs = np.zeros([lpz.shape[0]])
        char_list = [''] * lpz.shape[0]
        current_prob_sum = 0
        try:
            # Do until start is reached
            while t != 0 or c != 0:
                # Calculate the possible transition probabilities towards the current cell
                min_s = None
                min_switch_prob_delta = np.inf
                max_lpz_prob = max_prob
                for s in range(ground_truth.shape[1]): 
                    if ground_truth[c, s] != -1:                   
                        offset = offsets[c] - (offsets[c - 1 - s] if c - s > 0 else 0)
                        switch_prob = lpz[t + offsets[c], ground_truth[c, s]] if c > 0 else max_prob
                        est_switch_prob = table[t, c] - table[t - 1 + offset, c - 1 - s]
                        if abs(switch_prob - est_switch_prob) < min_switch_prob_delta:
                            min_switch_prob_delta = abs(switch_prob - est_switch_prob)
                            min_s = s

                        max_lpz_prob = max(max_lpz_prob, switch_prob)
                
                stay_prob = max(lpz[t + offsets[c], blank], max_lpz_prob) if t > 0 else max_prob
                est_stay_prob = table[t, c] - table[t - 1, c]
                
                # Check which transition has been taken
                if abs(stay_prob - est_stay_prob) > min_switch_prob_delta:
                    # Apply reverse switch transition
                    if c > 0:
                        # Log timing and character - frame alignment
                        for s in range(0, min_s + 1):
                            timings[c - s] = (offsets[c] + t) * 10 * 4 / 1000
                        char_probs[offsets[c] + t] = max_lpz_prob
                        char_list[offsets[c] + t] = train_args.char_list[ground_truth[c, min_s]]
                        current_prob_sum = 0

                    c -= 1 + min_s
                    t -= 1 - offset
                 
                else:
                    # Apply reverse stay transition
                    char_probs[offsets[c] + t] = stay_prob
                    char_list[offsets[c] + t] = "ε"
                    t -= 1
        except IndexError:
            # If the backtracking was not successful this usually means the window was too small
            window_len *= 2
            print("IndexError: Trying with win len: " + str(window_len))
            if window_len < 100000:
                continue
            else:
                raise

        break

    return timings, char_probs, char_list


def prepare_text(text):
    # Prepares the given text for alignment
    # Therefore we create a matrix of possible character symbols to represent the given text

    # Create list of char indices depending on the models char list
    ground_truth = "#"
    utt_begin_indices = []
    for utt in text:
        # Only one space in-between
        if ground_truth[-1] != " ":
            ground_truth += " "

        # Start new utterance remeber index
        utt_begin_indices.append(len(ground_truth) - 1)

        # Add chars of utterance
        for char in utt:
            if char.isspace():
                if ground_truth[-1] != " ":
                    ground_truth += " "
            elif char in train_args.char_list and char not in [ ".", ",", "-", "?", "!", ":", "»", "«", ";", "'", "›", "‹", "(", ")"]:
                ground_truth += char

    # Add space to the end
    if ground_truth[-1] != " ":
        ground_truth += " "
    utt_begin_indices.append(len(ground_truth) - 1)
        
    # Create matrix where first index is the time frame and the second index is the number of letters the character symbol spans
    max_char_len = max([len(c) for c in train_args.char_list])
    ground_truth_mat = np.ones([len(ground_truth), max_char_len], np.int) * -1    
    for i in range(len(ground_truth)):
        for s in range(max_char_len):
            if i-s < 0:
                continue
            span = ground_truth[i-s:i+1]
            span = span.replace(" ", '▁')
            if span in train_args.char_list:
                ground_truth_mat[i, s] = train_args.char_list.index(span)        
    
    return ground_truth_mat, utt_begin_indices


def write_output(out_path, utt_begin_indices, char_probs):
    # Uses char-wise alignments to get utterance-wise alignmentes and writes them into the given file

    with open(str(out_path), 'w') as outfile:
        outfile.write(str(path_wav.name) + '\n')
        
        def compute_time(index, type):
            # Compute start and end time of utterance.            
            middle = (timings[index] + timings[index - 1]) / 2
            if type == "begin":
                return max(timings[index + 1] - 0.5, middle)
            elif type == "end":
                return min(timings[index - 1] + 0.5, middle)

        for i in range(len(text)):
            start = compute_time(utt_begin_indices[i], "begin")
            end = compute_time(utt_begin_indices[i + 1], "end")
            start_t = int(round(start * 1000 / 40))
            end_t = int(round(end * 1000 / 40))

            # Compute confidence score by using the min mean probability after splitting into segments of 30 frames
            n = 30
            if end_t == start_t:
                min_avg = 0
            elif end_t - start_t <= n:
                min_avg = char_probs[start_t:end_t].mean()
            else:
                min_avg = 0
                for t in range(start_t, end_t - n):
                    min_avg = min(min_avg, char_probs[t:t + n].mean())
                    
            outfile.write(str(start) + " " + str(end) + " " + str(min_avg) + " | " + text[i] + '\n')


model_path = args.model_path
model_conf = None

# read training config
idim, odim, train_args = get_model_conf(model_path, model_conf)

space_id = train_args.char_list.index('▁')
train_args.char_list[0] = "ε"
train_args.char_list = [c.lower() for c in train_args.char_list]

data_path = Path(args.data_path)
eval_path = Path(args.eval_path)

for path_wav in data_path.glob("*.wav"):     

    chapter_sents = data_path / path_wav.name.replace(".wav", ".txt")
    chapter_prob = eval_path / path_wav.name.replace(".wav", ".npz")
    out_path = eval_path / path_wav.name.replace(".wav", ".txt")

    with open(str(chapter_sents), "r") as f:
        text = [t.strip() for t in f.readlines()]

    lpz = np.load(str(chapter_prob))["arr_0"]

    print("Syncing " + str(path_wav))
                       
    ground_truth_mat, utt_begin_indices = prepare_text(text)

    try:
        timings, char_probs, char_list = align(lpz, train_args.char_list, ground_truth_mat, utt_begin_indices, max_prob)
    except AssertionError:
        print("Skipping: Audio is shorter than text")
        continue

    write_output(out_path, utt_begin_indices, char_probs)

