#!/bin/bash

# Script para entrenar/afinar un modelo TDNN de cadena.
# Modificado para fine-tuning.

set -euo pipefail

# --- Opciones Configurables ---
stage=0 # Stage de este script run_tdnn.sh
train_set=train
gmm=tri3               # Directorio GMM base 
nnet3_affix="_vosk_ft" # Sufijo para el directorio de experimento de este TDNN

# Opciones para fine-tuning
tdnn_model_dir_for_ft=""        # Ruta al directorio AM del modelo Vosk 
ivector_extractor_dir_for_ft="" # Ruta al dir del extractor i-vector de Vosk 
num_epochs_ft=4                 # Número de épocas para fine-tuning
initial_lrate_ft=0.001          # Tasa de aprendizaje inicial para fine-tuning
final_lrate_ft=0.0001           # Tasa de aprendizaje final para fine-tuning

# Opciones originales de vosk-api/training/local/chain/run_tdnn.sh 
tree_affix=""     # Se usaba para _cleaned
train_stage=-10   # Stage interno para train.py (-10 suele ser para generar egs)
get_egs_stage=-10 # Stage interno para get_egs.sh
decode_iter=""    # Para decodificar una iteración específica (usualmente vacía)
decode_nj=10      # nj para decodificación

# Opciones de entrenamiento originales
chunk_width=140,100,160
common_egs_dir="" # Si se comparten egs entre experimentos
xent_regularize=0.1
dropout_schedule='0,0@0.20,0.5@0.50,0'
srand=0
remove_egs=true

decode_nj=2 
# --- Fin Opciones Configurables ---

echo "$0 $@" # Log del comando
. ./cmd.sh
. ./path.sh
. utils/parse_options.sh # Parsear opciones como --stage, --train_set, y las NUEVAS de fine-tuning

# --- Definición de Directorios ---
gmm_dir=exp/$gmm                   
ali_dir=exp/${gmm}_ali_${train_set} 

my_suffix_for_chain_exp=""

# Directorio base para los artefactos de cadena de este experimento
chain_exp_base_dir="exp/chain${nnet3_affix}" # e.g., exp/chain_vosk_ft

lang_chain_dir="$chain_exp_base_dir/lang_chain_topo"                 # Directorio lang con topología de cadena
tree_dir="$chain_exp_base_dir/tree_chain${tree_affix:+_$tree_affix}" # Árbol de cadena
lat_dir="$chain_exp_base_dir/${gmm}_${train_set}_lats"               # Lattices del GMM
# dir es el directorio final del modelo TDNN
tdnn_run_affix="_1a"
tdnn_output_dir="$chain_exp_base_dir/tdnn${tdnn_run_affix}" 
dir="$tdnn_output_dir"

# Datos de entrenamiento 
train_data_dir="data/${train_set}"
online_ivector_train_dir="$chain_exp_base_dir/ivectors_${train_set}"

echo "$0: Verificando archivos de entrada iniciales..."
for f in "$gmm_dir/final.mdl" "$train_data_dir/feats.scp" "$ali_dir/ali.1.gz"; do
  [ ! -f $f ] && echo "$0: Archivo esperado $f no encontrado." && exit 1
done
# Verificar opciones de fine-tuning si se pasaron
if [ ! -z "$tdnn_model_dir_for_ft" ] && [ ! -f "$tdnn_model_dir_for_ft/final.mdl" ]; then
  echo "$0: Directorio de modelo para fine-tuning especificado ($tdnn_model_dir_for_ft) pero final.mdl no encontrado."
  exit 1
fi
if [ ! -z "$ivector_extractor_dir_for_ft" ] && [ ! -f "$ivector_extractor_dir_for_ft/final.ie" ]; then
  echo "$0: Directorio de extractor i-vector para fine-tuning especificado ($ivector_extractor_dir_for_ft) pero final.ie no encontrado."
  exit 1
fi
echo "$0: Verificaciones iniciales de archivos completadas."

# --- ETAPA 9: iVectors, llamando a run_ivector_common.sh modificado ---
if [ $stage -le 9 ]; then
  echo "$0: Etapa 9: Preparando/Obteniendo i-vectors..."
  use_pretrained_extractor_opt=""
  pretrained_extractor_dir_opt=""
  if [ ! -z "$ivector_extractor_dir_for_ft" ]; then
    use_pretrained_extractor_opt="--use-pretrained-ivector-extractor true"
    pretrained_extractor_dir_opt="--pretrained-ivector-extractor-dir $ivector_extractor_dir_for_ft"
  fi

  local/chain/run_ivector_common.sh \
    --stage 0 \
    --train-set "${train_set}" \
    --gmm "${gmm}" \
    --suffix "${nnet3_affix}" \
    $use_pretrained_extractor_opt \
    $pretrained_extractor_dir_opt \
    --nj "${nj:-2}" ||
    {
      echo "ERROR en run_ivector_common.sh"
      exit 1
    }
fi

# --- ETAPA 10: Crear lang directory con topología de cadena ---
if [ $stage -le 10 ]; then
  echo "$0: Etapa 10: Creando directorio de lenguaje $lang_chain_dir con topología de cadena..."
  rm -rf "$lang_chain_dir"
  cp -r data/lang "$lang_chain_dir" 
  silphonelist=$(cat "$lang_chain_dir/phones/silence.csl")
  nonsilphonelist=$(cat "$lang_chain_dir/phones/nonsilence.csl")
  steps/nnet3/chain/gen_topo.py "$nonsilphonelist" "$silphonelist" >"$lang_chain_dir/topo" ||
    {
      echo "ERROR generando topo"
      exit 1
    }
fi

if [ ! -f "$lang_chain_dir/topo" ]; then
  echo "$0: Archivo esperado $lang_chain_dir/topo no encontrado DESPUÉS de la Etapa 10."
  exit 1
fi
echo "$0: Archivo topo verificado."

# --- ETAPA 11: Generar Lattices GMM ---
if [ $stage -le 11 ]; then
  echo "$0: Etapa 11: Generando lattices GMM desde alineamientos de $ali_dir para $train_data_dir..."
  steps/align_fmllr_lats.sh --nj "$decode_nj" --cmd "$train_cmd" \
    "$train_data_dir" "$lang_chain_dir" "$gmm_dir" "$lat_dir" || exit 1
fi

# --- ETAPA 12: Construir Árbol de Cadena ---
if [ $stage -le 12 ]; then
  echo "$0: Etapa 12: Construyendo árbol de cadena en $tree_dir usando alineamientos de $ali_dir..."
  steps/nnet3/chain/build_tree.sh \
    --frame-subsampling-factor 3 \
    --context-opts "--context-width=2 --central-position=1" \
    --cmd "$train_cmd" 2500 "$train_data_dir" \
    "$lang_chain_dir" \
    "$ali_dir" \
    "$tree_dir" || exit 1
fi

# --- ETAPA 13: Crear network.xconfig ---
if [ $stage -le 13 ]; then
  echo "$0: Etapa 13: Creando configs de red neuronal..."
  mkdir -p "$tdnn_output_dir/configs"
  num_targets=$(tree-info "$tree_dir/tree" | grep num-pdfs | awk '{print $2}')
  learning_rate_factor=$(echo "print(0.5/$xent_regularize)" | python3)

  # Configuración de red (del script original de vosk-api)
  # Asegúrate de que 'input dim' coincida con tus características (MFCC son 40D)
  # Y que 'ivector dim' coincida con tu extractor (40D en el script de vosk ivector).
  affine_opts="l2-regularize=0.008 dropout-proportion=0.0 dropout-per-dim=true dropout-per-dim-continuous=true"
  tdnnf_opts="l2-regularize=0.008 dropout-proportion=0.0 bypass-scale=0.75"
  linear_opts="l2-regularize=0.008 orthonormal-constraint=-1.0"
  prefinal_opts="l2-regularize=0.008"
  output_opts="l2-regularize=0.002"

  cat <<EOF >"$tdnn_output_dir/configs/network.xconfig"
  input dim=40 name=ivector 
  input dim=40 name=input


  idct-layer name=idct input=input dim=40 cepstral-lifter=22 affine-transform-file=$tdnn_output_dir/configs/idct.mat
  batchnorm-component name=batchnorm0 input=idct
  spec-augment-layer name=spec-augment freq-max-proportion=0.5 time-zeroed-proportion=0.2 time-mask-max-frames=20
  delta-layer name=delta input=spec-augment # Si tus características no tienen deltas, esto los añade. MFCC normales no los tienen.

  no-op-component name=input2 input=Append(delta, ReplaceIndex(ivector, t, 0))

  relu-batchnorm-dropout-layer name=tdnn1 $affine_opts dim=512 input=input2
  tdnnf-layer name=tdnnf2 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=1
  tdnnf-layer name=tdnnf3 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=1
  tdnnf-layer name=tdnnf4 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=1
  tdnnf-layer name=tdnnf5 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=0
  tdnnf-layer name=tdnnf6 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=3
  tdnnf-layer name=tdnnf7 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=3
  tdnnf-layer name=tdnnf8 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=3
  tdnnf-layer name=tdnnf9 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=3
  tdnnf-layer name=tdnnf10 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=3
  tdnnf-layer name=tdnnf11 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=3
  tdnnf-layer name=tdnnf12 $tdnnf_opts dim=512 bottleneck-dim=96 time-stride=3
  linear-component name=prefinal-l dim=192 $linear_opts

  prefinal-layer name=prefinal-chain input=prefinal-l $prefinal_opts small-dim=192 big-dim=512
  output-layer name=output include-log-softmax=false dim=$num_targets $output_opts

  prefinal-layer name=prefinal-xent input=prefinal-l $prefinal_opts small-dim=192 big-dim=512
  output-layer name=output-xent dim=$num_targets learning-rate-factor=$learning_rate_factor $output_opts
EOF
  # Crear el archivo idct.mat (matriz identidad si no hay transformación DCT previa)
  echo "[]" >"$tdnn_output_dir/configs/idct.mat"

  steps/nnet3/xconfig_to_configs.py --xconfig-file "$tdnn_output_dir/configs/network.xconfig" \
    --config-dir "$tdnn_output_dir/configs/" ||
    {
      echo "ERROR en xconfig_to_configs.py"
      exit 1
    }
fi

# --- ETAPA 14: Entrenamiento/Fine-tuning TDNN ---
if [ $stage -le 14 ]; then
  echo "$0: Iniciando entrenamiento/fine-tuning TDNN en $tdnn_output_dir"

  # Si estamos haciendo fine-tuning, preparamos el 0.mdl ANTES de llamar a train.py
  if [ ! -z "$tdnn_model_dir_for_ft" ] && [ -f "$tdnn_model_dir_for_ft/final.mdl" ]; then
    echo "$0: Preparando para fine-tuning desde $tdnn_model_dir_for_ft/final.mdl."
    echo "      Sobrescribiendo/creando $tdnn_output_dir/0.mdl con el modelo Vosk."
    echo "      (¡LAS ARQUITECTURAS DEBEN SER COMPATIBLES!)"

    nnet3-copy --edits="set-learning-rate-factor name=* learning-rate-factor=0.0" \
      "$tdnn_model_dir_for_ft/final.mdl" - |
      nnet3-copy --edits="set-learning-rate-factor name=* learning-rate-factor=1.0" \
        - "$tdnn_output_dir/0.mdl" ||
      {
        echo "Error transfiriendo pesos del modelo Vosk a $tdnn_output_dir/0.mdl."
        exit 1
      }
    echo "      Modelo base para fine-tuning preparado en $tdnn_output_dir/0.mdl."
  else
    echo "$0: Entrenando TDNN desde cero (o continuando si $tdnn_output_dir/final.mdl ya existe de un entrenamiento previo)."

  fi

  # Llamar a train.py.
  # El `train_stage` (e.g., -10) se encarga de las etapas de preparación de train.py (den.fst, egs, etc.).
  # Luego, el entrenamiento de la red comenzará desde la época 0, usando el $tdnn_output_dir/0.mdl existente.
  steps/nnet3/chain/train.py --stage "$train_stage" \
    --cmd "$cuda_cmd" \
    --feat.online-ivector-dir "$online_ivector_train_dir" \
    --feat.cmvn-opts "--norm-means=false --norm-vars=false" \
    --chain.xent-regularize "$xent_regularize" \
    --chain.leaky-hmm-coefficient 0.1 \
    --chain.l2-regularize 0.0 \
    --chain.apply-deriv-weights false \
    --chain.lm-opts="--num-extra-lm-states=2000" \
    --egs.cmd "$get_egs_cmd" \
    --egs.dir "$common_egs_dir" \
    --egs.stage "$get_egs_stage" \
    --egs.opts "--frames-overlap-per-eg 0 --constrained false" \
    --egs.chunk-width "$chunk_width" \
    --trainer.dropout-schedule "$dropout_schedule" \
    --trainer.add-option="--optimization.memory-compression-level=2" \
    --trainer.num-chunk-per-minibatch 64 \
    --trainer.frames-per-iter 2500000 \
    --trainer.num-epochs "$num_epochs_ft" \
    --trainer.optimization.num-jobs-initial 1 \
    --trainer.optimization.num-jobs-final 1 \
    --trainer.optimization.initial-effective-lrate "$initial_lrate_ft" \
    --trainer.optimization.final-effective-lrate "$final_lrate_ft" \
    --trainer.max-param-change 2.0 \
    --cleanup.remove-egs "$remove_egs" \
    --feat-dir "$train_data_dir" \
    --tree-dir "$tree_dir" \
    --lat-dir "$lat_dir" \
    --dir "$tdnn_output_dir" || exit 1
fi
