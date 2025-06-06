#!/bin/bash

# Script para preparar características comunes y i-vectors.
# Modificado para opcionalmente usar un extractor de i-vectors pre-entrenado.

set -euo pipefail 

# --- Opciones Configurables ---
stage=0
train_set=train # Conjunto de datos de entrenamiento (e.g., train o train_hires)
gmm=tri3        # Modelo GMM base para algunas operaciones (no siempre usado aquí)
suffix=""       # Sufijo para directorios de experimento (e.g., _vosk_ft)
nj=2

# Opciones para usar extractor pre-entrenado
use_pretrained_ivector_extractor=false
pretrained_ivector_extractor_dir="" # Ruta al dir del extractor de Vosk (contiene final.ie, online_cmvn.conf, etc.)

# --- Cargar Entorno y Parsear Opciones ---
. ./cmd.sh
. ./path.sh
. utils/parse_options.sh # Para procesar --stage, --train_set, etc.

# --- Definición de Directorios ---
gmm_dir=exp/${gmm} # No siempre se usa directamente aquí si el extractor es pre-entrenado

# Directorio base para los artefactos de cadena de este experimento
chain_exp_dir="exp/chain${suffix}"       # e.g., exp/chain_vosk_ft
extractor_dir="$chain_exp_dir/extractor" # Donde residirá el extractor (nuevo o copiado)

# --- Lógica Principal ---

if [ "$use_pretrained_ivector_extractor" = true ]; then
  if [ -z "$pretrained_ivector_extractor_dir" ] ||
    [ ! -f "$pretrained_ivector_extractor_dir/final.ie" ] ||
    [ ! -f "$pretrained_ivector_extractor_dir/final.dubm" ]; then # <<< AÑADIR VERIFICACIÓN PARA final.dubm
    echo "$0: ERROR: use_pretrained_ivector_extractor=true pero falta alguno de los siguientes en '$pretrained_ivector_extractor_dir':"
    echo "         final.ie, final.dubm"
    exit 1
  fi
  echo "$0: Usando extractor de i-vectors pre-entrenado de '$pretrained_ivector_extractor_dir'"

  mkdir -p "$extractor_dir"

  echo "INFO ($0): Copiando archivos del extractor pre-entrenado a $extractor_dir"
  cp "$pretrained_ivector_extractor_dir/final.ie" "$extractor_dir/final.ie" || exit 1
  cp "$pretrained_ivector_extractor_dir/final.dubm" "$extractor_dir/final.dubm" || exit 1 

  # Copiar online_cmvn.conf
  if [ -f "$pretrained_ivector_extractor_dir/online_cmvn.conf" ]; then
    cp "$pretrained_ivector_extractor_dir/online_cmvn.conf" "$extractor_dir/"
  else
    echo "ADVERTENCIA ($0): online_cmvn.conf no encontrado en $pretrained_ivector_extractor_dir. Puede ser necesario."
  fi

  # Copiar splice.conf Y crear splice_opts
  if [ -f "$pretrained_ivector_extractor_dir/splice.conf" ]; then
    cp "$pretrained_ivector_extractor_dir/splice.conf" "$extractor_dir/"
    if [ -s "$extractor_dir/splice.conf" ]; then
      cat "$extractor_dir/splice.conf" >"$extractor_dir/splice_opts"
      echo "INFO ($0): Archivo splice_opts creado en $extractor_dir a partir de splice.conf"
    fi
  else
    echo "ADVERTENCIA ($0): splice.conf no encontrado en $pretrained_ivector_extractor_dir."
  fi

  # Copiar global_cmvn.stats
  if [ -f "$pretrained_ivector_extractor_dir/global_cmvn.stats" ]; then
    cp "$pretrained_ivector_extractor_dir/global_cmvn.stats" "$extractor_dir/"
  else
    echo "ADVERTENCIA ($0): global_cmvn.stats no encontrado en $pretrained_ivector_extractor_dir. Creando uno vacío."
    touch "$extractor_dir/global_cmvn.stats"
  fi

  # Copiar otros archivos .mat si son necesarios (ej. final.mat)
  [ -f "$pretrained_ivector_extractor_dir/final.mat" ] && cp "$pretrained_ivector_extractor_dir/final.mat" "$extractor_dir/"

  if [ $stage -le 5 ]; then
    echo "$0: Saltando entrenamiento de UBM (etapa 4) y extractor de i-vectors (etapa 5)."
    stage=6
  fi

else
  # --- ENTRENAR EXTRACTOR DESDE CERO ---
  if [ $stage -le 4 ]; then
    echo "$0: Etapa 4: Entrenando UBM diagonal..."
    diag_ubm_dir="$chain_exp_dir/diag_ubm"
    mkdir -p "$diag_ubm_dir"
    temp_data_root="$diag_ubm_dir" # Para datos de subconjunto

    num_utts_total=$(wc -l <data/${train_set}/utt2spk)
    num_utts=$(($num_utts_total / 4))
    [ $num_utts -eq 0 ] && num_utts=$num_utts_total # Usar todo si es muy pequeño
    utils/data/subset_data_dir.sh "data/${train_set}" \
      "$num_utts" "${temp_data_root}/${train_set}_subset_ubm"

    steps/online/nnet2/train_diag_ubm.sh --cmd "$train_cmd" --nj "${nj:-10}" \
      --num-frames 700000 \
      --num-threads 8 \
      "${temp_data_root}/${train_set}_subset_ubm" 512 \
      "$extractor_dir" "$diag_ubm_dir" || exit 1
  fi

  if [ $stage -le 5 ]; then
    echo "$0: Etapa 5: Entrenando extractor de i-vectors en $extractor_dir..."
    steps/online/nnet2/train_ivector_extractor.sh --cmd "$train_cmd" --nj "${nj:-2}" \
      --ivector-dim 40 \
      "data/${train_set}" "$chain_exp_dir/diag_ubm" \
      "$extractor_dir" || exit 1
  fi
fi

# --- ETAPA 6: Extracción de i-vectors ---
# Siempre se ejecuta, usando el $extractor_dir (que ahora contiene el pre-entrenado o el recién entrenado)
if [ $stage -le 6 ]; then
  echo "$0: Etapa 6: Extrayendo i-vectors para data/${train_set} usando extractor de $extractor_dir"
  ivector_data_dir="data/${train_set}"                    # Datos sobre los que extraer i-vectors
  ivectors_out_dir="$chain_exp_dir/ivectors_${train_set}" # Directorio de salida

  # Directorio temporal para datos con speaker info modificada (max2)
  temp_data_root_max2="${ivectors_out_dir}/${train_set}_max2_tmp"
  mkdir -p "$temp_data_root_max2"

  utils/data/modify_speaker_info.sh --utts-per-spk-max 2 \
    "$ivector_data_dir" "${temp_data_root_max2}/${train_set}_max2"

  steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj "${nj:-10}" \
    "${temp_data_root_max2}/${train_set}_max2" \
    "$extractor_dir" \
    "$ivectors_out_dir" || exit 1

  # Limpiar directorio temporal _max2 si se desea
  # rm -rf "$temp_data_root_max2"
fi

echo "$0: Proceso de i-vectors completado."
exit 0
