import 'dart:math';

/// The season of [date], by meteorological season in the northern
/// hemisphere: December to February is winter, and so on.
String seasonOf(DateTime date) => switch (date.month) {
  12 || 1 || 2 => 'WINTER',
  3 || 4 || 5 => 'SPRING',
  6 || 7 || 8 => 'SUMMER',
  _ => 'AUTUMN',
};

/// The first day of [date]'s season (local midnight): 1 December,
/// 1 March, 1 June or 1 September.
DateTime seasonStart(DateTime date) {
  // Months since the season began: 0, 1 or 2.
  final into = date.month % 3;
  return DateTime(date.year, date.month - into);
}

/// The last day of [date]'s season (local midnight): the end of February,
/// May, August or November.
DateTime seasonEnd(DateTime date) {
  final start = seasonStart(date);
  // Day 0 of the next season's first month is the season's last day.
  return DateTime(start.year, start.month + 3, 0);
}

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
/// a number, `AUTUMN-OTTER-4821`. Easy to say, but easy to guess too
/// (about 19 random bits, the season known): offered only on request, for
/// Member codes; a blank code gets the auth API's random one (60 bits).
String suggestVoucherCode({DateTime? now, Random? random}) {
  final rng = random ?? Random.secure();
  final animal = voucherAnimals[rng.nextInt(voucherAnimals.length)];
  final number = 100 + rng.nextInt(9900);
  return '${seasonOf(now ?? DateTime.now())}-$animal-$number';
}

/// A chosen code's fewest letters and digits (dashes aside), and its most
/// characters with dashes, as the auth API checks. Redeeming takes any code
/// up to [maxVoucherCode]: older ones may be shorter.
const minVoucherCode = 10;
const maxVoucherCode = 40;

/// Whether the auth API takes [typed] as a new chosen code: letters and
/// digits in words (spaces, dashes or underscores between them), at least
/// [minVoucherCode] letters and digits, and at most [maxVoucherCode]
/// characters once joined by single dashes.
bool isValidVoucherCode(String typed) {
  final words = typed.split(RegExp(r'[\s_-]+')).where((w) => w.isNotEmpty);
  final code = words.join('-');
  return words.join().length >= minVoucherCode &&
      code.length <= maxVoucherCode &&
      RegExp(r'^[A-Za-z0-9-]+$').hasMatch(code);
}
