"""Cloud recognition's pet labels (specs/cloud-recognition.md, "Breeds and
coats"): the breeds and coats SigLIP2 picks among, as text embeddings.

Writes, next to the function's other resources:

- pet-labels.tsv: one label a line, `species <TAB> type <TAB> label <TAB>
  prompt`. species: cat or dog; type: breed, coat, or none (a breed it may
  pick that names no breed worth showing: a mixed breed, or one told apart
  by its coat or tail, which the coat label says better);
- pet-labels.bin: their text embeddings, in order, unit length, 768
  float32s each (little-endian).

And prints the model's logit scale (PetLabels.SCALE).

usage: python pet_labels.py <resources dir>
       python pet_labels.py --eval <vision onnx> <oxford pets dir> [crops dir]

The second form measures the labels as the function runs them: the ONNX
vision tower on 224 x 224 RGB bytes, on the Oxford-IIIT Pet test set (and
on crops, if given). Needs open_clip_torch, onnxruntime, pillow, numpy.
"""
import os
import sys

import numpy as np

ARCH = "hf-hub:timm/ViT-B-16-SigLIP2"  # google/siglip2-base-patch16-224, Apache-2.0

CAT_BREEDS = [
    "Abyssinian", "Balinese", "Bengal", "Birman", "British Shorthair", "Burmese",
    "Cornish Rex", "Devon Rex", "Egyptian Mau", "Exotic Shorthair", "Himalayan",
    "Maine Coon", "Norwegian Forest Cat", "Ocicat", "Oriental Shorthair", "Persian",
    "Ragdoll", "Savannah", "Scottish Fold", "Selkirk Rex", "Siamese", "Siberian",
    "Sphynx", "Tonkinese", "Turkish Angora", "Turkish Van",
]
# Picked, never shown: house cats, and breeds told apart by a coat (the coat
# label says it: a Bombay is a black cat to a camera) or a tail.
CAT_NONE = [
    "Domestic Shorthair", "Domestic Longhair", "Bombay", "Russian Blue",
    "Chartreux", "Korat", "Manx",
]
DOG_BREEDS = [
    "Afghan Hound", "Airedale Terrier", "Akita", "Alaskan Malamute", "American Bulldog",
    "American Pit Bull Terrier", "Australian Cattle Dog", "Australian Shepherd", "Basenji",
    "Basset Hound", "Beagle", "Belgian Malinois", "Bernese Mountain Dog", "Bichon Frise",
    "Bloodhound", "Border Collie", "Border Terrier", "Boston Terrier", "Boxer", "Brittany",
    "Bull Terrier", "Bulldog", "Cairn Terrier", "Cane Corso", "Cavalier King Charles Spaniel",
    "Chihuahua", "Chow Chow", "Cocker Spaniel", "Collie", "Dachshund", "Dalmatian",
    "Dobermann", "English Setter", "French Bulldog", "German Shepherd",
    "German Shorthaired Pointer", "Golden Retriever", "Great Dane", "Great Pyrenees",
    "Greyhound", "Havanese", "Irish Setter", "Italian Greyhound", "Jack Russell Terrier",
    "Japanese Chin", "Keeshond", "Labrador Retriever", "Leonberger", "Lhasa Apso", "Maltese",
    "Miniature Pinscher", "Miniature Schnauzer", "Newfoundland", "Papillon", "Pekingese",
    "Pembroke Welsh Corgi", "Pomeranian", "Poodle", "Pug", "Rhodesian Ridgeback",
    "Rottweiler", "Saint Bernard", "Samoyed", "Schnauzer", "Scottish Terrier", "Shar Pei",
    "Shetland Sheepdog", "Shiba Inu", "Shih Tzu", "Siberian Husky",
    "Staffordshire Bull Terrier", "Vizsla", "Weimaraner", "West Highland White Terrier",
    "Wheaten Terrier", "Whippet", "Yorkshire Terrier",
]
DOG_NONE = ["Mixed-breed"]
# (label, how the prompt says it)
CAT_COATS = [
    ("black", "black"), ("white", "white"), ("gray", "gray"), ("orange", "orange (ginger)"),
    ("cream", "cream"), ("tabby", "tabby"), ("black and white", "black and white (tuxedo)"),
    ("calico", "calico"), ("tortoiseshell", "tortoiseshell"),
    ("colorpoint", "colorpoint (pale body, dark face and paws)"),
]
DOG_COATS = [
    ("black", "black"), ("white", "white"), ("brown", "brown"), ("golden", "golden"),
    ("cream", "cream"), ("gray", "gray"), ("black and tan", "black and tan"),
    ("black and white", "black and white"), ("brindle", "brindle"), ("spotted", "spotted"),
    ("merle", "merle"),
]

# Oxford-IIIT Pet's breeds, as named here (the --eval set).
OXFORD = {
    "Abyssinian": "Abyssinian", "Bengal": "Bengal", "Birman": "Birman", "Bombay": "Bombay",
    "British_Shorthair": "British Shorthair", "Egyptian_Mau": "Egyptian Mau",
    "Maine_Coon": "Maine Coon", "Persian": "Persian", "Ragdoll": "Ragdoll",
    "Russian_Blue": "Russian Blue", "Siamese": "Siamese", "Sphynx": "Sphynx",
    "american_bulldog": "American Bulldog", "american_pit_bull_terrier": "American Pit Bull Terrier",
    "basset_hound": "Basset Hound", "beagle": "Beagle", "boxer": "Boxer", "chihuahua": "Chihuahua",
    "english_cocker_spaniel": "Cocker Spaniel", "english_setter": "English Setter",
    "german_shorthaired": "German Shorthaired Pointer", "great_pyrenees": "Great Pyrenees",
    "havanese": "Havanese", "japanese_chin": "Japanese Chin", "keeshond": "Keeshond",
    "leonberger": "Leonberger", "miniature_pinscher": "Miniature Pinscher",
    "newfoundland": "Newfoundland", "pomeranian": "Pomeranian", "pug": "Pug",
    "saint_bernard": "Saint Bernard", "samoyed": "Samoyed", "scottish_terrier": "Scottish Terrier",
    "shiba_inu": "Shiba Inu", "staffordshire_bull_terrier": "Staffordshire Bull Terrier",
    "wheaten_terrier": "Wheaten Terrier", "yorkshire_terrier": "Yorkshire Terrier",
}


def labels():
    rows = []
    for species, breeds, none, coats in (("cat", CAT_BREEDS, CAT_NONE, CAT_COATS),
                                         ("dog", DOG_BREEDS, DOG_NONE, DOG_COATS)):
        for b in breeds:
            rows.append((species, "breed", b, f"a photo of a {b}, a type of {species}."))
        for b in none:
            rows.append((species, "none", b, f"a photo of a {b}, a type of {species}."))
        for label, said in coats:
            rows.append((species, "coat", f"{label} {species}", f"a photo of a {said} {species}."))
    return rows


def model():
    import open_clip
    import torch
    m, _, _ = open_clip.create_model_and_transforms(ARCH)
    return m.eval(), open_clip.get_tokenizer(ARCH), torch


def write(out):
    m, tok, torch = model()
    rows = labels()
    with torch.no_grad():
        t = m.encode_text(tok([r[3] for r in rows])).float()
    t = torch.nn.functional.normalize(t, dim=-1).numpy().astype("<f4")
    with open(os.path.join(out, "pet-labels.tsv"), "w") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    t.tofile(os.path.join(out, "pet-labels.bin"))
    print(f"{len(rows)} labels, {t.shape[1]} values each; scale {m.logit_scale.exp().item():.4f}")


# --- --eval: as the function runs (PetLabels / Siglip2) ---

BREED_SURE = float(os.environ.get("BREED_SURE", "0.7"))
COAT_SURE = float(os.environ.get("COAT_SURE", "0.5"))


def describe(vectors, rows, text, scale, species):
    """Each crop's labels: [(label, type, confidence)], as PetLabels.describe."""
    out = []
    for v in vectors:
        found = []
        for kinds, sure in ((("breed", "none"), BREED_SURE), (("coat",), COAT_SURE)):
            idx = [i for i, r in enumerate(rows) if r[0] == species and r[1] in kinds]
            logits = scale * (text[idx] @ v)
            p = np.exp(logits - logits.max())
            p /= p.sum()
            j = int(p.argmax())
            row = rows[idx[j]]
            if row[1] != "none" and p[j] >= sure:
                found.append((row[2], row[1], float(p[j])))
        out.append(found)
    return out


def pixels(path):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    s = max(im.size)
    sq = Image.new("RGB", (s, s))
    sq.paste(im, ((s - im.size[0]) // 2, (s - im.size[1]) // 2))
    return np.asarray(sq.resize((224, 224), Image.BILINEAR), dtype=np.uint8)


def evaluate(onnx_path, pets, crops=None):
    import time
    import onnxruntime as ort
    m, tok, torch = model()
    scale = m.logit_scale.exp().item()
    rows = labels()
    with torch.no_grad():
        text = torch.nn.functional.normalize(m.encode_text(tok([r[3] for r in rows])).float(), dim=-1).numpy()
    so = ort.SessionOptions()
    so.intra_op_num_threads = 2
    sess = ort.InferenceSession(onnx_path, so)

    def embed(batch):
        x = (np.stack(batch).astype(np.float32) / 255 - 0.5) / 0.5
        out = sess.run(["pooler_output"], {"pixel_values": x.transpose(0, 3, 1, 2)})[0]
        return out / np.linalg.norm(out, axis=1, keepdims=True)

    test = [line.split() for line in open(f"{pets}/annotations/test.txt")]
    per = {}
    for img, *_ in test:
        per.setdefault(img.rsplit("_", 1)[0], []).append(img)
    rng = np.random.default_rng(0)
    picked = [(k, i) for k in sorted(per) for i in rng.choice(per[k], min(30, len(per[k])), replace=False)]
    shown = right = 0
    t0 = time.time()
    for s in range(0, len(picked), 8):
        chunk = picked[s:s + 8]
        vs = embed([pixels(f"{pets}/images/{i}.jpg") for _, i in chunk])
        for (k, _), v in zip(chunk, vs):
            species = "cat" if k[0].isupper() else "dog"
            breeds = [l for l, t, _ in describe([v], rows, text, scale, species)[0] if t == "breed"]
            if breeds:
                shown += 1
                right += breeds[0] == OXFORD[k]
    dt = (time.time() - t0) / len(picked)
    print(f"Oxford pets ({len(picked)}): a breed shown on {shown / len(picked):.1%}, right {right / max(shown, 1):.1%}"
          f" (breeds >= {BREED_SURE}); {dt * 1000:.0f} ms a crop, 2 threads")
    if crops:
        from collections import Counter
        files = sorted(f for f in os.listdir(crops) if f.endswith(".jpg"))
        found = Counter()
        for s in range(0, len(files), 8):
            vs = embed([pixels(f"{crops}/{f}") for f in files[s:s + 8]])
            for f, labs in zip(files[s:s + 8], describe(vs, rows, text, scale, "cat")):
                who = "suerte" if "suerte" in f else "other"
                found[(who, "none")] += not labs
                for l, t, _ in labs:
                    found[(who, l)] += 1
        n = Counter("suerte" if "suerte" in f else "other" for f in files)
        print(f"crops: {dict(n)}")
        for (who, l), c in sorted(found.items(), key=lambda x: (x[0][0], -x[1])):
            print(f"  {who:7} {l:22} {c}")


if __name__ == "__main__":
    if sys.argv[1] == "--eval":
        evaluate(*sys.argv[2:])
    else:
        write(sys.argv[1])
