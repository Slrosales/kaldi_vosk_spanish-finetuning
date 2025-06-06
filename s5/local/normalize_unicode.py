#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
import unicodedata
import re

def normalize_word_for_kaldi_lexicon(text_orig): # Nombre cambiado y lógica unificada
    # Asegurarse de que text_orig es un string antes de strip()
    if not isinstance(text_orig, str):
        text_orig = str(text_orig) # O manejar el error como prefieras

    text = text_orig.upper().strip()
    
    # Reemplazos específicos para manejar cómo se separan las palabras clave
    text = text.replace('/', ' ') 
    text = text.replace('&', ' Y ') 
    text = text.replace('-', ' ') 
    text = text.replace('_', ' ') # Guiones bajos también a espacios

    text_nfd = unicodedata.normalize('NFD', text)
    text_no_diacritics = ''.join(c for c in text_nfd if unicodedata.category(c) != 'Mn')
    
    text_no_diacritics = text_no_diacritics.replace('Ñ', 'N')
    text_no_diacritics = text_no_diacritics.replace('Ü', 'U')
    
    # Mantener solo letras, números y ESPACIOS (temporalmente para palabras compuestas)
    processed_text = re.sub(r'[^A-Z0-9N ]', '', text_no_diacritics)
    # Convertir múltiples espacios a uno solo y quitar al inicio/final
    processed_text = re.sub(r'\s+', ' ', processed_text).strip()

    # Lógica final para la clave del lexicón:
    # Si la palabra original (antes de reemplazar / & - _) no tenía espacios
    # Y la processed_text ahora SÍ tiene espacios (porque / & - _ se volvieron espacios),
    # entonces eliminamos esos espacios para tener una sola clave en el lexicón.
    # Ej: "TCP/IP" (orig) -> "TCP IP" (proc) -> "TCPIP" (final_key)
    # Ej: "R&D" (orig) -> "R Y D" (proc) -> "RYD" (final_key)
    # Ej: "BIG DATA" (orig) -> "BIG DATA" (proc) -> "BIG DATA" (final_key, se mantienen espacios)
    
    original_had_no_internal_spaces = (' ' not in text_orig.strip())
    
    if original_had_no_internal_spaces and ' ' in processed_text:
        final_key = processed_text.replace(' ', '')
    else:
        final_key = processed_text
    
    # Si después de todo el procesamiento, la clave está vacía, devolver algo.
    if not final_key:
        return "UNK_SYMBOL_NORM" # O simplemente una cadena vacía para ser filtrada después
    return final_key

if __name__ == "__main__":
    for line in sys.stdin:
        # Cada línea de stdin es una palabra o frase a normalizar
        normalized_line = normalize_word_for_kaldi_lexicon(line.strip())
        if normalized_line: # Solo imprimir si no es vacía
            sys.stdout.write(normalized_line + '\n')