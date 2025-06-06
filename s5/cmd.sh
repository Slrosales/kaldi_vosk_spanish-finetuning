# you can change cmd.sh depending on what type of queue you are using.
# If you have no queueing system and want to run on a local machine, you
# can change all instances 'queue.pl' to run.pl (but be careful and run
# commands one by one: most recipes will exhaust the memory on your
# machine).  queue.pl works with GridEngine (qsub).  slurm.pl works
# with slurm.  Different queues are configured differently, with different
# queue names and different ways of specifying things like memory;
# to account for these differences you can create and edit the file
# conf/queue.conf to match your queue's configuration.  Search for
# conf/queue.conf in http://kaldi-asr.org/doc/queue.html for more information,
# or search for the string 'default_config' in utils/queue.pl or utils/slurm.pl.

# --- Comandos para Ejecución en CPU/GPU ---

# cuda_cmd: Usado por scripts de entrenamiento de redes neuronales (como train.py)
# Si tienes GPU y Kaldi compilado con CUDA:
export cuda_cmd="run.pl --gpu 1"
# Si NO tienes GPU o quieres forzar CPU para esta parte (no recomendado para TDNNs):
# export cuda_cmd="run.pl"

# get_egs_cmd: Usado para la generación de ejemplos (egs) para el entrenamiento de la red.
# Esto puede ser intensivo en CPU/IO. Ajusta la memoria si es necesario.
export get_egs_cmd="run.pl --mem 4G" 

# train_cmd: Comando general de entrenamiento, usado por muchos scripts de steps/
# Puede ser el mismo que cuda_cmd si quieres que todo el entrenamiento GMM/DNN use GPU.
export train_cmd="run.pl --gpu 1"
# O si quieres que GMMs (Etapa 3) usen CPU:
# export train_cmd="run.pl" # (Y luego cuda_cmd se usaría específicamente para train.py)

# decode_cmd: Para decodificación.
export decode_cmd="run.pl --mem 4G"

# mkgraph_cmd: Para crear grafos.
export mkgraph_cmd="run.pl --mem 2G"

# Si necesitas un comando específico para CPU para ciertos pasos de entrenamiento (GMMs por ejemplo)
export train_cmd_cpu="run.pl"

# --- Otras Configuraciones ---
export PYTHONUNBUFFERED=1 # Útil para que la salida de Python no se quede en buffer.

# Configuración para queue.pl si usas un sistema de colas como GridEngine
# export QUEUE_OPTS='-q all.q -l ram_free=1G,mem_free=1G' 
# export train_cmd="queue.pl ${QUEUE_OPTS}"
# export decode_cmd="queue.pl ${QUEUE_OPTS} --mem 2G"
# export cuda_cmd="queue.pl ${QUEUE_OPTS} --gpu 1"