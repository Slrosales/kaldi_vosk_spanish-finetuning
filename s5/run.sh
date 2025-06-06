#!/usr/bin/env bash

stage=0        
stop_stage=100 
nj=2
train_set="train"      
gmm="tri3"             
nnet3_affix="_vosk_ft" 

# Opciones de Fine-tuning TDNN
tdnn_model_dir_for_ft="../exp/vosk_model_base/am"             
ivector_extractor_dir_for_ft="../exp/vosk_model_base/ivector" 
num_epochs_ft=3
initial_lrate_ft=0.0001
final_lrate_ft=0.00001
# --- Fin de la declaración de opciones ---

# Asegurar que los scripts de Kaldi estén en el PATH
. ./path.sh || {
  echo "Error: path.sh falló"
  exit 1
}
# Cargar configuraciones de ejecución (GPU, etc.)
. ./cmd.sh || {
  echo "Error: cmd.sh falló"
  exit 1
}
# Para controlar etapas con --stage y --stop-stage
. utils/parse_options.sh || {
  echo "Error: utils/parse_options.sh falló. Asegúrate de que esté en $PWD/utils/"
  exit 1
}

# Definición de etapas por defecto (si no se pasan por línea de comandos)
stage=${stage:-0}
stop_stage=${stop_stage:-100}

CORPUS_DOWNLOAD_DIR="CorporaOpenSLR" 

# --- Etapa 0: Data Prep ---
if [ $stage -le 0 ] && [ $stop_stage -ge 0 ]; then
  echo "=== Etapa 0: Preparación de Datos ==="
  local/data_prep.sh local/databases.txt "$CORPUS_DOWNLOAD_DIR" || {
    echo "Error en data_prep.sh"
    exit 1
  }
  echo "=== Etapa 0: Preparación de Datos Finalizada ==="
fi

# --- Etapa 1: Extracción de Características (MFCC) ---
mfccdir=mfcc_output
nj=2 # Número de trabajos paralelos 

if [ $stage -le 1 ] && [ $stop_stage -ge 1 ]; then
  echo "=== Etapa 1: Extracción de Características MFCC ==="
  for x in train dev test; do
    if [ ! -f conf/mfcc.conf ]; then
      echo "Error: conf/mfcc.conf no encontrado. Asegúrate de que sea el de Vosk."
      exit 1
    fi
    steps/make_mfcc.sh --cmd "$train_cmd" --nj "$nj" \
      data/$x exp/make_mfcc/$x "$mfccdir" || {
      echo "Error en make_mfcc.sh para data/$x"
      exit 1
    }
    steps/compute_cmvn_stats.sh \
      data/$x exp/make_mfcc/$x "$mfccdir" || {
      echo "Error en compute_cmvn_stats.sh para data/$x"
      exit 1
    }
    utils/validate_data_dir.sh data/$x || {
      echo "Error validando data/$x después de MFCC"
      exit 1
    }
  done
  echo "=== Etapa 1: Extracción de Características MFCC Finalizada ==="
fi

# --- Etapa 2: Preparación del Lenguaje y Diccionario ---
if [ $stage -le 2 ] && [ $stop_stage -ge 2 ]; then
  echo "=== Etapa 2: Preparación del Lenguaje (Diccionario y Modelo de Lenguaje) ==="

  # lang_prep.sh usa $CORPUS_DOWNLOAD_DIR como primer argumento si necesita acceder a T22.full.dic desde allí.
  # Si T22.full.dic está en data/local/ o similar, ajusta la llamada o el script.
  # IMPORTANTE: lang_prep.sh debe ser modificado para usar el vocabulario de data/train/text
  # y no solo depender de un diccionario fijo.
  local/lang_prep.sh "$CORPUS_DOWNLOAD_DIR" || {
    echo "Error en local/lang_prep.sh"
    exit 1
  }

  rm -f data/local/dict/lexiconp.txt # Eliminar lexiconp.txt si existe, para que prepare_lang lo regenere limpiamente

  utils/prepare_lang.sh data/local/dict "<UNK>" data/local/lang_tmp data/lang || {
    echo "Error en utils/prepare_lang.sh"
    exit 1
  }

  # LM Prep: lm_prep.sh usa data/train/text y data/test/text internamente.
  local/lm_prep.sh || {
    echo "Error en local/lm_prep.sh"
    exit 1
  }
  echo "=== Etapa 2: Preparación del Lenguaje Finalizada ==="
fi

# --- Etapa 3: Entrenamiento GMM (Monofónico, Trifónico Básico, LDA+MLLT) ---
# N_HMM y N_GAUSSIANS son de la receta dimex100. Puedes experimentar con estos valores.
# Los valores por defecto de los scripts steps/... suelen ser razonables también.
N_HMM=${N_HMM:-2500}              # Aumentado un poco respecto a dimex100, similar a vosk-api/training
N_GAUSSIANS=${N_GAUSSIANS:-15000} # Aumentado un poco

gmm_tree_dir=exp/tri3 # Usaremos tri3 para el árbol, similar a vosk-api/training

if [ $stage -le 3 ] && [ $stop_stage -ge 3 ]; then
  echo "=== Etapa 3: Entrenamiento de Modelos GMM (hasta LDA+MLLT) ==="

  steps/train_mono.sh --boost-silence 1.25 --nj "$nj" --cmd "$train_cmd" \
    data/train data/lang exp/mono || {
    echo "Error en train_mono.sh"
    exit 1
  }

  steps/align_si.sh --boost-silence 1.25 --nj "$nj" --cmd "$train_cmd" \
    data/train data/lang exp/mono exp/mono_ali || {
    echo "Error en align_si.sh para mono"
    exit 1
  }

  steps/train_deltas.sh --boost-silence 1.25 --cmd "$train_cmd" \
    "$N_HMM" "$N_GAUSSIANS" data/train data/lang exp/mono_ali exp/tri1 || {
    echo "Error en train_deltas.sh para tri1"
    exit 1
  }

  steps/align_si.sh --nj "$nj" --cmd "$train_cmd" \
    data/train data/lang exp/tri1 exp/tri1_ali || {
    echo "Error en align_si.sh para tri1"
    exit 1
  }

  # Modelo Trifónico LDA+MLLT (similar al tri2 del script de vosk-api/training)
  steps/train_lda_mllt.sh --cmd "$train_cmd" \
    --splice-opts "--left-context=3 --right-context=3" \
    "$N_HMM" "$N_GAUSSIANS" data/train data/lang exp/tri1_ali exp/tri2 || {
    echo "Error en train_lda_mllt.sh para tri2 (LDA+MLLT)"
    exit 1
  }

  steps/align_si.sh --nj "$nj" --cmd "$train_cmd" \
    data/train data/lang exp/tri2 exp/tri2_ali || {
    echo "Error en align_si.sh para tri2"
    exit 1
  }

  N_GAUSSIANS_TRI3=${N_GAUSSIANS_TRI3:-20000}
  steps/train_lda_mllt.sh --cmd "$train_cmd" \
    --splice-opts "--left-context=3 --right-context=3" \
    "$N_HMM" "$N_GAUSSIANS_TRI3" data/train data/lang exp/tri2_ali $gmm_tree_dir || {
    echo "Error en train_lda_mllt.sh para $gmm_tree_dir"
    exit 1
  }

  echo "Alineando datos con el modelo final GMM ($gmm_tree_dir)..."
  steps/align_si.sh --nj "$nj" --cmd "$train_cmd" \
    data/train data/lang "$gmm_tree_dir" "${gmm_tree_dir}_ali_${train_set}" || { # Crea exp/tri3_ali_train
    echo "Error en align_si.sh para $gmm_tree_dir"
    exit 1
  }

  echo "=== Etapa 3: Entrenamiento GMM Finalizado. El árbol está en $gmm_tree_dir/tree ==="
fi

# --- Etapa 4: Fine-Tuning TDNN con Modelo Vosk ---
if [ $stage -le 4 ] && [ $stop_stage -ge 4 ]; then
  echo "=== Etapa 4: Fine-Tuning TDNN con Modelo Vosk ==="

  # Directorios necesarios
  # gmmdir="exp/tri3"                       # Tu mejor GMM de la Etapa 3
  vosk_model_dir="../exp/vosk_model_base" # Donde está el final.mdl y final.ie de Vosk

  local/chain/run_tdnn.sh \
    --stage 0 \
    --train_set "${train_set}" \
    --gmm "${gmm}" \
    --nnet3_affix "_vosk_ft" \
    --tdnn_model_dir_for_ft "$vosk_model_dir/am" \
    --ivector_extractor_dir_for_ft "$vosk_model_dir/ivector" \
    --num_epochs_ft "${num_epochs_ft:-3}" \
    --initial_lrate_ft "${initial_lrate_ft:-0.0001}" \
    --final_lrate_ft "${final_lrate_ft:-0.00001}" \
    --decode_nj "${nj:-2}" ||
    {
      echo "Error en fine-tuning TDNN (local/chain/run_tdnn.sh)"
      exit 1
    }

  echo "=== Etapa 4: Fine-Tuning TDNN Finalizado. Modelo en $dir ==="
fi

# --- Etapa 5: Decodificación y Resultados ---
if [ $stage -le 5 ] && [ $stop_stage -ge 5 ]; then
  echo "=== Etapa 5: Decodificación con Modelo TDNN Afinado ==="

  chain_exp_base_dir="exp/chain${nnet3_affix}" 

  model_dir="${chain_exp_base_dir}/tdnn_1a" 
  lang_dir_with_G="data/lang_test_tg"

  ivector_extractor_dir_for_decode="${chain_exp_base_dir}/extractor" 

  tree_for_graph="${chain_exp_base_dir}/tree_chain"
  graph_name="graph_tg"
  graph_dir="$model_dir/${graph_name}"

  # Verificar archivos necesarios
  if [ ! -f "$model_dir/final.mdl" ]; then
    echo "ERROR: $model_dir/final.mdl no encontrado."
    exit 1
  fi
  if [ ! -d "$lang_dir_with_G" ] || [ ! -f "$lang_dir_with_G/G.fst" ]; then
    echo "ERROR: $lang_dir_with_G/G.fst no encontrado."
    exit 1
  fi

  # La verificación ahora usará la ruta correcta
  if [ ! -d "$ivector_extractor_dir_for_decode" ] || [ ! -f "$ivector_extractor_dir_for_decode/final.ie" ]; then
    echo "ERROR: Extractor de i-vectors '$ivector_extractor_dir_for_decode/final.ie' no encontrado para decodificación."
    exit 1
  fi
  if [ ! -d "$tree_for_graph" ]; then
    echo "ERROR: Directorio de árbol de cadena $tree_for_graph no encontrado."
    exit 1
  fi

  # Crear enlace simbólico para el árbol dentro del directorio del modelo para mkgraph.sh
  if [ ! -e "$model_dir/tree" ]; then # -e verifica si existe (archivo, dir, o enlace)
    echo "Creando enlace simbólico para el árbol en $model_dir/tree -> $tree_for_graph/tree"
    # Asegurarse que el directorio $model_dir exista
    mkdir -p "$(dirname "$model_dir/tree")" # Crea $model_dir si no existe
    ln -rsf "$tree_for_graph/tree" "$model_dir/tree" || {
      echo "Error creando enlace simbólico para el árbol."
      exit 1
    }
  fi

  echo "Creando grafo de decodificación en $graph_dir..."
  utils/mkgraph.sh "${lang_dir_with_G}" "${model_dir}" "${graph_dir}" ||
    {
      echo "Error creando el grafo de decodificación con mkgraph.sh"
      exit 1
    }

  # Decodificar conjuntos dev y test
  for dset in dev test; do
    echo "Decodificando conjunto: $dset"
    ivecs_dset_dir="${chain_exp_base_dir}/ivectors_${dset}" 

    if [ ! -f "$ivecs_dset_dir/ivector_online.scp" ]; then
      echo "Extrayendo i-vectors para $dset..."
      temp_dset_max2_dir="${ivecs_dset_dir}/${dset}_max2_tmp" # Directorio temporal
      mkdir -p "$temp_dset_max2_dir"

      utils/data/modify_speaker_info.sh --utts-per-spk-max 2 \
        "data/${dset}" "${temp_dset_max2_dir}/${dset}_max2"

      steps/online/nnet2/extract_ivectors_online.sh --cmd "$decode_cmd" --nj "$nj" \
        "${temp_dset_max2_dir}/${dset}_max2" \
        "$ivector_extractor_dir_for_decode" \
        "$ivecs_dset_dir" || {
        echo "Error extrayendo i-vectors para $dset"
        exit 1
      }
    fi

    steps/nnet3/decode.sh --acwt 1.0 --post-decode-acwt 10.0 \
      --nj "$nj" --cmd "$decode_cmd" \
      --online-ivector-dir "$ivecs_dset_dir" \
      "$graph_dir" "data/$dset" "$model_dir/decode_${dset}_${graph_name}" ||
      {
        echo "Error decodificando $dset"
        exit 1
      }
  done

  echo "Resultados del Word Error Rate (WER) (sin re-scorear con LM grande):"
  for x in $model_dir/decode_*; do [ -d $x ] && grep WER $x/wer_* | utils/best_wer.sh; done
  echo "=== Etapa 5: Decodificación Finalizada ==="
fi

echo "Fin del script de run.sh"
