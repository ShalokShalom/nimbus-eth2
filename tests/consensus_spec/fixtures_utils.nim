# beacon_chain
# Copyright (c) 2018-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  std/[os, strutils, typetraits],
  # Internals
  ../../beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  ../../beacon_chain/spec/[
    eth2_merkleization, eth2_ssz_serialization, forks],
  # Status libs,
  snappy,
  stew/byteutils

export
  eth2_merkleization, eth2_ssz_serialization

# Process current EF test format
# ---------------------------------------------

# #######################
# Path parsing

func forkForPathComponent*(forkPath: string): Opt[BeaconStateFork] =
  for fork in BeaconStateFork:
    if ($fork).toLowerAscii() == forkPath:
      return ok fork
  err()

# #######################
# JSON deserialization

func readValue*(r: var JsonReader, a: var seq[byte]) =
  ## Custom deserializer for seq[byte]
  a = hexToSeqByte(r.readValue(string))

# #######################
# Mock RuntimeConfig

func genesisTestRuntimeConfig*(stateFork: BeaconStateFork): RuntimeConfig =
  var res = defaultRuntimeConfig
  case stateFork
  of BeaconStateFork.Bellatrix:
    res.BELLATRIX_FORK_EPOCH = GENESIS_EPOCH
    res.ALTAIR_FORK_EPOCH = GENESIS_EPOCH
  of BeaconStateFork.Altair:
    res.ALTAIR_FORK_EPOCH = GENESIS_EPOCH
  of BeaconStateFork.Phase0:
    discard
  res

# #######################
# Test helpers

type
  UnconsumedInput* = object of CatchableError
  TestSizeError* = object of ValueError

  # https://github.com/ethereum/consensus-specs/tree/v1.2.0-rc.1/tests/formats/rewards#rewards-tests
  Deltas* = object
    rewards*: List[uint64, Limit VALIDATOR_REGISTRY_LIMIT]
    penalties*: List[uint64, Limit VALIDATOR_REGISTRY_LIMIT]

  # https://github.com/ethereum/consensus-specs/blob/v1.2.0-rc.3/specs/phase0/validator.md#eth1block
  Eth1Block* = object
    timestamp*: uint64
    deposit_root*: Eth2Digest
    deposit_count*: uint64
    # All other eth1 block fields

const
  FixturesDir* =
    currentSourcePath.rsplit(DirSep, 1)[0] / ".." / ".." / "vendor" / "nim-eth2-scenarios"
  SszTestsDir* = FixturesDir / "tests-v" & SPEC_VERSION
  MaxObjectSize* = 3_000_000

proc parseTest*(path: string, Format: typedesc[Json], T: typedesc): T =
  try:
    # debugEcho "          [Debug] Loading file: \"", path, '\"'
    result = Format.loadFile(path, T)
  except SerializationError as err:
    writeStackTrace()
    stderr.write $Format & " load issue for file \"", path, "\"\n"
    stderr.write err.formatMsg(path), "\n"
    quit 1

template readFileBytes*(path: string): seq[byte] =
  cast[seq[byte]](readFile(path))

proc sszDecodeEntireInput*(input: openArray[byte], Decoded: type): Decoded =
  let stream = unsafeMemoryInput(input)
  var reader = init(SszReader, stream)
  reader.readValue(result)

  if stream.readable:
    raise newException(UnconsumedInput, "Remaining bytes in the input")

iterator walkTests*(dir: static string): string =
   for kind, path in walkDir(
       dir/"pyspec_tests", relative = true, checkDir = true):
     yield path

proc parseTest*(path: string, Format: typedesc[SSZ], T: typedesc): T =
  try:
    # debugEcho "          [Debug] Loading file: \"", path, '\"'
    sszDecodeEntireInput(snappy.decode(readFileBytes(path), MaxObjectSize), T)
  except SerializationError as err:
    writeStackTrace()
    stderr.write $Format & " load issue for file \"", path, "\"\n"
    stderr.write err.formatMsg(path), "\n"
    quit 1

proc loadForkedState*(
    path: string, fork: BeaconStateFork): ref ForkedHashedBeaconState =
  # TODO stack usage. newClone and assignClone do not seem to
  # prevent temporaries created by case objects
  let forkedState = new ForkedHashedBeaconState
  case fork
  of BeaconStateFork.Bellatrix:
    let state = newClone(parseTest(path, SSZ, bellatrix.BeaconState))
    forkedState.kind = BeaconStateFork.Bellatrix
    forkedState.bellatrixData.data = state[]
    forkedState.bellatrixData.root = hash_tree_root(state[])
  of BeaconStateFork.Altair:
    let state = newClone(parseTest(path, SSZ, altair.BeaconState))
    forkedState.kind = BeaconStateFork.Altair
    forkedState.altairData.data = state[]
    forkedState.altairData.root = hash_tree_root(state[])
  of BeaconStateFork.Phase0:
    let state = newClone(parseTest(path, SSZ, phase0.BeaconState))
    forkedState.kind = BeaconStateFork.Phase0
    forkedState.phase0Data.data = state[]
    forkedState.phase0Data.root = hash_tree_root(state[])
  forkedState
