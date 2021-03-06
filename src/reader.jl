# BED Reader
# ==========

mutable struct Reader <: BioCore.IO.AbstractReader
    state::BioCore.Ragel.State
    index::Union{GenomicFeatures.Indexes.Tabix,Nothing}

    function Reader(input::BufferedStreams.BufferedInputStream, index=nothing)
        return new(BioCore.Ragel.State(file_machine.start_state, input), index)
    end
end

"""
    BED.Reader(input::IO; index=nothing)
    BED.Reader(input::AbstractString; index=:auto)

Create a data reader of the BED file format.

The first argument specifies the data source. When it is a filepath that ends
with *.bgz*, it is considered to be block compression file format (BGZF) and the
function will try to find a tabix index file (<filename>.tbi) and read it if
any. See <http://www.htslib.org/doc/tabix.html> for bgzip and tabix tools.

Arguments
---------
- `input`: data source
- `index`: path to a tabix file
"""
function Reader(input::IO; index=nothing)
    if isa(index, AbstractString)
        index = GenomicFeatures.Indexes.Tabix(index)
    end
    return Reader(BufferedStreams.BufferedInputStream(input), index)
end

function Reader(filepath::AbstractString; index=:auto)
    if isa(index, Symbol) && index != :auto
        throw(ArgumentError("invalid index argument: ':$(index)'"))
    end
    if endswith(filepath, ".bgz")
        input = BGZFStreams.BGZFStream(filepath)
        if index == :auto
            index = GenomicFeatures.Indexes.findtabix(filepath)
        end
    else
        input = open(filepath)
    end
    return Reader(input, index = index)
end

function Base.eltype(::Type{Reader})
    return Record
end

function BioCore.IO.stream(reader::Reader)
    return reader.state.stream
end

const record_machine, file_machine = (function ()
    cat = Automa.RegExp.cat
    rep = Automa.RegExp.rep
    opt = Automa.RegExp.opt

    record = let
        chrom = re"[ -~]*"
        chrom.actions[:enter] = [:mark]
        chrom.actions[:exit] = [:record_chrom]

        chromstart = re"[0-9]+"
        chromstart.actions[:enter] = [:mark]
        chromstart.actions[:exit] = [:record_chromstart]

        chromend = re"[0-9]+"
        chromend.actions[:enter] = [:mark]
        chromend.actions[:exit] = [:record_chromend]

        name = re"[ -~]*"
        name.actions[:enter] = [:mark]
        name.actions[:exit] = [:record_name]

        score = re"[0-9]+"
        score.actions[:enter] = [:mark]
        score.actions[:exit] = [:record_score]

        strand = re"[+\-.?]"
        strand.actions[:enter] = [:record_strand]

        thickstart = re"[0-9]+"
        thickstart.actions[:enter] = [:mark]
        thickstart.actions[:exit] = [:record_thickstart]

        thickend = re"[0-9]+"
        thickend.actions[:enter] = [:mark]
        thickend.actions[:exit] = [:record_thickend]

        itemrgb = cat(re"[0-9]+", opt(cat(',', re"[0-9]+", ',', re"[0-9]+")))
        itemrgb.actions[:enter] = [:mark]
        itemrgb.actions[:exit] = [:record_itemrgb]

        blockcount = re"[0-9]+"
        blockcount.actions[:enter] = [:mark]
        blockcount.actions[:exit] = [:record_blockcount]

        # comma-separated values
        csv(x) = cat(rep(cat(x, ',')), opt(x))

        blocksizes = let
            blocksize = re"[0-9]+"
            blocksize.actions[:enter] = [:mark]
            blocksize.actions[:exit] = [:record_blocksizes_blocksize]

            csv(blocksize)
        end
        blocksizes.actions[:exit] = [:record_blocksizes]

        blockstarts = let
            blockstart = re"[0-9]+"
            blockstart.actions[:enter] = [:mark]
            blockstart.actions[:exit] = [:record_blockstarts_blockstart]

            csv(blockstart)
        end
        blockstarts.actions[:exit] = [:record_blockstarts]

        cat(
            chrom, '\t',
            chromstart, '\t',
            chromend,
            opt(cat('\t', name,
            opt(cat('\t', score,
            opt(cat('\t', strand,
            opt(cat('\t', thickstart,
            opt(cat('\t', thickend,
            opt(cat('\t', itemrgb,
            opt(cat('\t', blockcount,
            opt(cat('\t', blocksizes,
            opt(cat('\t', blockstarts)))))))))))))))))))
    end
    record.actions[:enter] = [:anchor]
    record.actions[:exit] = [:record]

    newline = let
        lf = re"\n"
        lf.actions[:enter] = [:countline]

        cat(opt('\r'), lf)
    end

    file = rep(cat(record, newline))

    return map(Automa.compile, (record, file))
end)()

#=
write("bed.dot", Automa.machine2dot(file_machine))
run(`dot -Tsvg -o bed.svg bed.dot`)
=#

const record_actions = Dict(
    :record_chrom => :(record.chrom = (mark:p - 1) .- offset; record.ncols += 1),
    :record_chromstart => :(record.chromstart = (mark:p - 1) .- offset; record.ncols += 1),
    :record_chromend => :(record.chromend = (mark:p - 1) .- offset; record.ncols += 1),
    :record_name => :(record.name = (mark:p - 1) .- offset; record.ncols += 1),
    :record_score => :(record.score = (mark:p - 1) .- offset; record.ncols += 1),
    :record_strand => :(record.strand = p - offset; record.ncols += 1),
    :record_thickstart => :(record.thickstart = (mark:p - 1) .- offset; record.ncols += 1),
    :record_thickend => :(record.thickend = (mark:p - 1) .- offset; record.ncols += 1),
    :record_itemrgb => :(record.itemrgb = (mark:p - 1) .- offset; record.ncols += 1),
    :record_blockcount => :(record.blockcount = (mark:p - 1) .- offset; record.ncols += 1),
    :record_blocksizes_blocksize => :(push!(record.blocksizes, (mark:p - 1) .- offset)),
    :record_blocksizes => :(record.ncols += 1),
    :record_blockstarts_blockstart => :(push!(record.blockstarts, (mark:p - 1) .- offset)),
    :record_blockstarts => :(record.ncols += 1),
    :record => :(record.filled = 1:p - 1),
    :countline => :(),
    :mark => :(mark = p),
    :anchor => :())
eval(
    BioCore.ReaderHelper.generate_index_function(
        Record,
        record_machine,
        :(offset = mark = 0),
        record_actions))
eval(
    BioCore.ReaderHelper.generate_read_function(
        Reader,
        file_machine,
        :(offset = mark = 0),
        merge(record_actions, Dict(
            :record => quote
                BioCore.ReaderHelper.resize_and_copy!(record.data, data, BioCore.ReaderHelper.upanchor!(stream):p - 1)
                record.filled = (offset + 1:p - 1) .- offset
                found_record = true
                @escape
            end,
            :countline => :(linenum += 1),
            :anchor => :(BioCore.ReaderHelper.anchor!(stream, p); offset = p - 1)))))
