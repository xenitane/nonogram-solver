pub const SerializationError = error{
    InvalidInput,
    ExtraLines,
    NoDimensionProvided,
    ExtraDimension,
    EmptyBlock,
    BlockSizeNotPresent,
    ExtraBlockParameters,
    LineCountMismatch,
};

pub const NonogramErrors = error{
    InvalidData,
    InvalidIndex,
    InvalidLineData,
    LineDataAlreadyExist,
    PixelCountMismatch,
    Unsolvable,
};
