import os
import csv
import random
import zipfile
import numpy as np
from scipy.io import wavfile

# Настройки датасета
NUM_FILES = 2000
DURATION = 5.0       # 3 секунды
SAMPLE_RATE = 16000  # 16 кГц
FREQ_MIN = 100
FREQ_MAX = 8000

dataset_dir = "audio_dataset_500_3s"
os.makedirs(dataset_dir, exist_ok=True)

metadata = []
print("Генерируем 500 аудиофайлов по 3 секунды...")

random.seed(42)

for i in range(1, NUM_FILES + 1):
    freq = random.randint(FREQ_MIN, FREQ_MAX)
    file_name = f"sine_{freq}hz_{i}.wav"
    file_path = os.path.join(dataset_dir, file_name)
    
    # Генерация синусоиды
    t = np.linspace(0, DURATION, int(SAMPLE_RATE * DURATION), endpoint=False)
    audio_data = np.sin(2 * np.pi * freq * t)
    audio_data = (audio_data * 32767).astype(np.int16) # 16-bit PCM
    
    wavfile.write(file_path, SAMPLE_RATE, audio_data)
    metadata.append({"file_name": file_name, "frequency": freq})

# Создание файла разметки
csv_path = os.path.join(dataset_dir, "metadata.csv")
with open(csv_path, mode="w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=["file_name", "frequency"])
    writer.writeheader()
    writer.writerows(metadata)

print("Упаковка в ZIP-архив...")
zip_name = "audio_dataset_500_3s.zip"
with zipfile.ZipFile(zip_name, 'w', zipfile.ZIP_DEFLATED) as zipf:
    for root, dirs, files in os.walk(dataset_dir):
        for file in files:
            full_path = os.path.join(root, file)
            zipf.write(full_path, os.path.relpath(full_path, os.path.dirname(dataset_dir)))

print(f"Успешно! Архив '{zip_name}' создан в папке со скриптом.")
