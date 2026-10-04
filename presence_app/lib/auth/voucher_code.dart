import 'dart:math';

/// The season of [date], by meteorological season in the northern
/// hemisphere: December to February is winter, and so on.
String seasonOf(DateTime date) => switch (date.month) {
  12 || 1 || 2 => 'WINTER',
  3 || 4 || 5 => 'SPRING',
  6 || 7 || 8 => 'SUMMER',
  _ => 'AUTUMN',
};

/// The animals a suggested code picks from.
const voucherAnimals = [
  'ALPACA',
  'BADGER',
  'BEAVER',
  'BISON',
  'CAMEL',
  'CHEETAH',
  'COBRA',
  'CONDOR',
  'COYOTE',
  'CRANE',
  'DINGO',
  'DOLPHIN',
  'EAGLE',
  'FALCON',
  'FERRET',
  'FINCH',
  'GAZELLE',
  'GECKO',
  'GIBBON',
  'GIRAFFE',
  'GOOSE',
  'HERON',
  'HIPPO',
  'HYENA',
  'IBEX',
  'IGUANA',
  'JACKAL',
  'JAGUAR',
  'KOALA',
  'LEMUR',
  'LEOPARD',
  'LLAMA',
  'LYNX',
  'MARMOT',
  'MEERKAT',
  'MOOSE',
  'NARWHAL',
  'OCELOT',
  'ORCA',
  'OSPREY',
  'OTTER',
  'PANDA',
  'PANTHER',
  'PELICAN',
  'PENGUIN',
  'PUFFIN',
  'PUMA',
  'QUOKKA',
  'RACCOON',
  'RAVEN',
  'SALMON',
  'SEAL',
  'SPARROW',
  'STORK',
  'TAPIR',
  'TIGER',
  'TOUCAN',
  'TURTLE',
  'WALRUS',
  'WOMBAT',
  'WOLF',
  'YAK',
  'ZEBRA',
];

/// A code to suggest for a new voucher: the current season, an animal and
/// a number, `AUTUMN-OTTER-4821`.
String suggestVoucherCode({DateTime? now, Random? random}) {
  final rng = random ?? Random.secure();
  final animal = voucherAnimals[rng.nextInt(voucherAnimals.length)];
  final number = 100 + rng.nextInt(9900);
  return '${seasonOf(now ?? DateTime.now())}-$animal-$number';
}

/// The length of a chosen code, dashes included (as the auth API checks).
const minVoucherCode = 6;
const maxVoucherCode = 40;

/// Whether the auth API takes [typed] as a chosen code: letters and digits
/// in words (spaces, dashes or underscores between them), 6 to 40
/// characters once joined by single dashes.
bool isValidVoucherCode(String typed) {
  final code = typed
      .split(RegExp(r'[\s_-]+'))
      .where((w) => w.isNotEmpty)
      .join('-');
  return code.length >= minVoucherCode &&
      code.length <= maxVoucherCode &&
      RegExp(r'^[A-Za-z0-9-]+$').hasMatch(code);
}
