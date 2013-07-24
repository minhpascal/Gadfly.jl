
require("Codecs")
require("Compose")
require("DataFrames")
require("Distributions")
require("Iterators")
require("JSON")
require("WebSockets")

module Gadfly

using Codecs
using Color
using Compose
using DataFrames
using JSON

import Iterators
import Compose.draw, Compose.hstack, Compose.vstack
import JSON.to_json
import Base.copy, Base.push!, Base.start, Base.next, Base.done, Base.has,
       Base.show, Base.getindex

export Plot, Layer, Scale, Coord, Geom, Guide, Stat, render, plot, layer, @plot, spy

# Re-export some essentials from Compose
export D3, SVG, PNG, PS, PDF, draw, inch, mm, px, pt, color

typealias ColorOrNothing Union(ColorValue, Nothing)


element_aesthetics(::Any) = []
default_scales(::Any) = []


abstract Element
abstract ScaleElement       <: Element
abstract CoordinateElement  <: Element
abstract GeometryElement    <: Element
abstract GuideElement       <: Element
abstract StatisticElement   <: Element


include("misc.jl")
include("ticks.jl")
include("color.jl")
include("theme.jl")
include("aesthetics.jl")
include("data.jl")
include("weave.jl")
include("poetry.jl")


# We maintain a dictionary of every Data abject in layer that's been added to
# a plot, indexed by object id. This lets us serialize Plots while only
# sending a reference to the data, and not the data itself, which can be too
# costly.
const DATA_INDEX = Dict{Uint64, Union(Nothing, AbstractDataFrame)}()


# A plot has zero or more layers. Layers have a particular geometry and their
# own data, which is inherited from the plot if not given.
type Layer <: Element
    # populated when the layer is added to the plot
    data::Union(Data, Nothing)

    data_source::Union(AbstractDataFrame, Nothing)
    mapping::Dict
    statistic::StatisticElement
    geom::GeometryElement

    function Layer()
        new(nothing, nothing, Dict(), Stat.nil, Geom.nil)
    end

    function Layer(data_source::Union(Nothing, AbstractDataFrame), mapping::Dict,
                   statistic::StatisticElement, geom::GeometryElement)
        new(nothing, data_source, Dict(), statistic, geom)
    end
end


function layer(data::Union(AbstractDataFrame, Nothing),
               statistic::StatisticElement=Stat.nil,
               geom::GeometryElement=Geom.nil;
               mapping...)
    Layer(data, Dict(mapping...), statistic, geom)
end


function layer(statistic::StatisticElement,
               geom::GeometryElement;
               mapping...)
    layer(nothing, statistic, geom; mapping...)
end


function layer(geom::GeometryElement; mapping...)
    layer(nothing, Stat.nil, geom; mapping...)
end


# A full plot specification.
type Plot
    layers::Vector{Layer}
    data_source::Union(Nothing, AbstractDataFrame)
    data::Data
    scales::Vector{ScaleElement}
    statistics::Vector{StatisticElement}
    coord::CoordinateElement
    guides::Vector{GuideElement}
    theme::Theme
    mapping::Dict

    function Plot()
        new(Layer[], nothing, Data(), ScaleElement[], StatisticElement[],
            Coord.cartesian, GuideElement[], default_theme)
    end
end


function add_plot_element(p::Plot, arg::GeometryElement)
    layer = Layer()
    layer.geom = arg
    add_plot_element(p, layer)
end

function add_plot_element(p::Plot, arg::ScaleElement)
    push!(p.scales, arg)
end

function add_plot_element(p::Plot, arg::StatisticElement)
    if isempty(p.layers)
        add_plot_element(p, Layer())
    end

    p.layers[end].statistic = arg
end

function add_plot_element(p::Plot, arg::CoordinateElement)
    push!(p.coordinates, arg)
end

function add_plot_element(p::Plot, arg::GuideElement)
    push!(p.guides, arg)
end

function add_plot_element(p::Plot, layer::Layer)
    # Inherit mappings or data from the Plot where they are missing in the Layer.
    if layer.data_source === nothing && isempty(layer.mapping)
        layer.data = p.data
        layer.data_source = p.data_source
        layer.mapping = p.mapping
    else
        if layer.data_source === nothing
            layer.data_source = p.data_source
        end

        if isempty(layer.mapping)
            layer.mapping = p.mapping
        end

        layer.data = Data()
        for (k, v) in layer.mapping
            setfield(layer.data, k, eval_plot_mapping(layer.data_source, v))
        end
    end

    DATA_INDEX[object_id(layer.data_source)] = layer.data_source

    push!(p.layers, layer)
end


eval_plot_mapping(data::AbstractDataFrame, arg::Symbol) = data[string(arg)]
eval_plot_mapping(data::AbstractDataFrame, arg::String) = data[arg]
eval_plot_mapping(data::AbstractDataFrame, arg::Integer) = data[arg]
eval_plot_mapping(data::AbstractDataFrame, arg::Expr) = with(data, arg)

# Acceptable types of values that can be bound to aesthetics.
typealias AestheticValue Union(Nothing, Symbol, String, Integer, Expr)


# Create a new plot.
#
# Grammar of graphics style plotting consists of specifying a dataset, one or
# more plot elements (scales, coordinates, geometries, etc), and binding of
# aesthetics to columns or expressions of the dataset.
#
# For example, a simple scatter plot would look something like:
#
#     plot(my_data, Geom.point, x="time", y="price")
#
# Where "time" and "price" are the names of columns in my_data.
#
# Args:
#   data: Data to be bound to aesthetics.
#   mapping: Aesthetics symbols (e.g. :x, :y, :color) mapped to
#            names of columns in the data frame or other expressions.
#   elements: Geometries, statistics, etc.

function plot(data_source::AbstractDataFrame, elements::Element...; mapping...)
    p = Plot()
    p.mapping = {k => v for (k, v) in mapping}
    p.data_source = data_source
    DATA_INDEX[object_id(data_source)] = data_source
    build_plot_data(p)

    for element in elements
        add_plot_element(p, element)
    end

    p
end

# Build the "data" field in a Plot object.
#
# This assumes the mapping and data_source fields have been populated. The
# mapping is then evaluated in the context of the data_source.
function build_plot_data(p::Plot)
    valid_aesthetics = Set(names(Aesthetics)...)
    for (k, v) in p.mapping
        if !contains(valid_aesthetics, k)
            error("$(k) is not a recognized aesthetic")
        end

        if !(typeof(v) <: AestheticValue)
            error(
            """Aesthetic $(k) is mapped to a value of type $(typeof(v)).
               It must be mapped to a string, symbol, or expression.""")
        end

        setfield(p.data, k, eval_plot_mapping(p.data_source, v))
    end
end


# The old fashioned (pre named arguments) version of plot.
#
# This version takes an explicit mapping dictionary, mapping aesthetics symbols
# to expressions or columns in the data frame.
#
# Args:
#   data: Data to be bound to aesthetics.
#   mapping: Dictionary of aesthetics symbols (e.g. :x, :y, :color) to
#            names of columns in the data frame or other expressions.
#   elements: Geometries, statistics, etc.
#
# Returns:
#   A Plot object.
#
function plot(data::AbstractDataFrame, mapping::Dict, elements::Element...)
    p = Plot()
    p.mapping = mapping
    p.data_source = data
    for element in elements
        add_plot_element(p, element)
    end

    for (var, value) in mapping
        setfield(p.data, var, eval_plot_mapping(data, value))
    end

    p
end


# Turn a graph specification into a graphic.
#
# This is where magic happens (sausage is made). Processing all the parts of the
# plot is actually pretty simple. It's made complicated by trying to handle
# defaults. With that aside, plots are made in the following steps.
#
#    I. Apply scales to transform raw data to the form expected by the aesthetic.
#   II. Apply statistics to the scaled data. Statistics are essentially functions
#       that map one or more aesthetics to one or more aesthetics.
#  III. Apply coordinates. Currently all this does is figure out the coordinate
#       system used by the plot panel canvas.
#   IV. Render geometries. This gives us one or more compose forms suitable to be
#       composed with the plot's panel.
#    V. Render guides. Guides are conceptually very similar to geometries but with
#       the ability to be placed outside of the plot panel.
#
#  Finally there is a very important call to layout_guides which puts everything
#  together.
#
# Args:
#   plot: a plot to render.
#
# Returns:
#   A compose Canvas containing the graphic.
#
function render(plot::Plot)
    if isempty(plot.layers)
        error("Plot has no layers. Try adding a geometry.")
    end

    datas = [layer.data for layer in plot.layers]

    # Add default statistics for geometries.
    layer_stats = Array(StatisticElement, length(plot.layers))
    for (i, layer) in enumerate(plot.layers)
        layer_stats[i] = is(layer.statistic, Stat.nil) ?
                            Geom.default_statistic(layer.geom) : layer.statistic
    end

    used_aesthetics = Set{Symbol}()
    for layer in plot.layers
        union!(used_aesthetics, element_aesthetics(layer.geom))
    end

    for stat in layer_stats
        union!(used_aesthetics, element_aesthetics(stat))
    end

    defined_unused_aesthetics = setdiff(Set(keys(plot.mapping)...), used_aesthetics)
    if !isempty(defined_unused_aesthetics)
        warn("The following aesthetics are mapped, but not used by any geometry:\n    ",
             join([string(a) for a in defined_unused_aesthetics], ", "))
    end

    scaled_aesthetics = Set{Symbol}()
    for scale in plot.scales
        union!(scaled_aesthetics, element_aesthetics(scale))
    end

    # Only one scale can be applied to an aesthetic (without getting some weird
    # and incorrect results), so we organize scales into a dict.
    scales = Dict{Symbol, ScaleElement}()
    for scale in plot.scales
        for var in element_aesthetics(scale)
            scales[var] = scale
        end
    end

    unscaled_aesthetics = setdiff(used_aesthetics, scaled_aesthetics)

    # Add default scales for statistics.
    for stat in layer_stats
        for scale in default_scales(stat)
            # Use the statistics default scale only when it covers some
            # aesthetic that is not already scaled.
            scale_aes = Set(element_aesthetics(scale)...)
            if !isempty(intersect(scale_aes, unscaled_aesthetics))
                for var in scale_aes
                    scales[var] = scale
                end
                setdiff!(unscaled_aesthetics, scale_aes)
            end
        end
    end

    # Assign scales to mapped aesthetics first.
    for var in unscaled_aesthetics
        if !haskey(plot.mapping, var)
            continue
        end

        t = classify_data(getfield(plot.data, var))
        if haskey(default_aes_scales[t], var)
            scale = default_aes_scales[t][var]
            scale_aes = Set(element_aesthetics(scale)...)
            for var in scale_aes
                scales[var] = scale
            end
        end
    end

    for var in unscaled_aesthetics
        if haskey(plot.mapping, var) || haskey(scales, var)
            continue
        end

        if haskey(default_aes_scales[:discrete], var)
            scale = default_aes_scales[:discrete][var]
            scale_aes = Set(element_aesthetics(scale)...)
            for var in scale_aes
                scales[var] = scale
            end
        end
    end

    # There can be at most one instance of each guide. This is primarily to
    # prevent default guides being applied over user-supplied guides.
    guides = Dict{Type, GuideElement}()
    for guide in plot.guides
        guides[typeof(guide)] = guide
    end
    guides[Guide.PanelBackground] = Guide.background
    guides[Guide.XTicks] = Guide.x_ticks
    guides[Guide.YTicks] = Guide.y_ticks

    statistics = copy(plot.statistics)
    push!(statistics, Stat.x_ticks)
    push!(statistics, Stat.y_ticks)

    function mapped_and_used(vs)
        any([haskey(plot.mapping, v) && contains(used_aesthetics, v) for v in vs])
    end

    function choose_name(vs)
        for v in vs
            if haskey(plot.mapping, v)
                return string(plot.mapping[v])
            end
        end
        ""
    end

    if mapped_and_used(Scale.x_vars) && !haskey(guides, Guide.XLabel)
        guides[Guide.XLabel] =  Guide.XLabel(choose_name(Scale.x_vars))
    end

    if mapped_and_used(Scale.y_vars) && !haskey(guides, Guide.YLabel)
        guides[Guide.YLabel] = Guide.YLabel(choose_name(Scale.y_vars))
    end

    # I. Scales
    aess = Scale.apply_scales(Iterators.distinct(values(scales)), datas...)

    # set default labels
    if has(plot.mapping, :color)
        aess[1].color_key_title = string(plot.mapping[:color])
    end

    # IIa. Layer-wise statistics
    for (layer_stat, aes) in zip(layer_stats, aess)
        Stat.apply_statistics(StatisticElement[layer_stat], scales, aes)
    end

    # IIb. Plot-wise Statistics
    plot_aes = cat(aess...)
    Stat.apply_statistics(statistics, scales, plot_aes)

    # Add some default guides determined by defined aesthetics
    if !all([aes.color === nothing for aes in [plot_aes, aess...]]) &&
       !has(guides, Guide.ColorKey)
        guides[Guide.ColorKey] = Guide.colorkey
    end

    # III. Coordinates
    plot_canvas = Coord.apply_coordinate(plot.coord, plot_aes, aess...)

    # Now that coordinates are set, layer aesthetics inherit plot aesthetics.
    for aes in aess
        inherit!(aes, plot_aes)
    end

    # IV. Geometries
    plot_canvas = compose(plot_canvas,
                          [render(layer.geom, plot.theme, aes)
                           for (layer, aes) in zip(plot.layers, aess)]...)

    # V. Guides
    guide_canvases = {}
    for guide in values(guides)
        append!(guide_canvases, render(guide, plot.theme, aess))
    end

    canvas = Guide.layout_guides(plot_canvas, plot.theme, guide_canvases...)

    # TODO: This is a kludge. Axis labels sometimes extend past the edge of the
    # canvas.
    pad(canvas, 5mm)
end


# A convenience version of Compose.draw that let's you skip the call to render.
draw(backend::Compose.Backend, p::Plot) = draw(backend, render(p))

# Convenience stacking functions
vstack(ps::Plot...) = vstack([render(p) for p in ps]...)
hstack(ps::Plot...) = hstack([render(p) for p in ps]...)


# Displaying plots, for interactive use.
#
# This is a show function that, rather than outputing a totally incomprehensible
# representation of the Plot object, renders it, and emits the graphic. (Which
# usually means, shows it in a browser window.)
#
function show(io::IO, p::Plot)
    draw(SVG(6inch, 5inch), p)
end
# TODO: Find a more elegant way to automatically show plots. This is unexpected
# and gives weave problems.


include("scale.jl")
include("coord.jl")
include("geometry.jl")
include("guide.jl")
include("statistics.jl")


# All aesthetics must have a scale. If none is given, we use a default.
# The default depends on whether the input is discrete or continuous (i.e.,
# PooledDataVector or DataVector, respectively).
const default_aes_scales = {
        :continuous => {:x     => Scale.x_continuous,
                        :x_min => Scale.x_continuous,
                        :x_max => Scale.x_continuous,
                        :y     => Scale.y_continuous,
                        :y_min => Scale.y_continuous,
                        :y_max => Scale.y_continuous,
                        :color => Scale.color_gradient,
                        :label => Scale.label},
        :discrete   => {:x     => Scale.x_discrete,
                        :x_min => Scale.x_discrete,
                        :x_max => Scale.x_discrete,
                        :y     => Scale.y_discrete,
                        :y_min => Scale.y_discrete,
                        :y_max => Scale.y_discrete,
                        :color => Scale.color_hue,
                        :label => Scale.label}}

# Determine whether the input is discrete or continuous.
classify_data{N}(data::DataArray{Float64, N}) = :continuous
classify_data{N}(data::DataArray{Float32, N}) = :continuous
classify_data(data::DataArray) = :discrete
classify_data(data::PooledDataArray) = :discrete

# Very long unfactorized integer data should be treated as continuous
function classify_data{T <: Integer}(data::DataVector{T})
    length(Set{T}(data...)) <= 20 ? :discrete : :continuous
end


# Serialize a Plot object.
function serialize(plot::Plot; with_data=false)
    out = Dict()
    out["layers"] = {serialize(layer, with_data=with_data) for layer in plot.layers}
    out["scales"] = {Scale.serialize_scale(scale) for scale in plot.scales}
    out["statistics"] = {Stat.serialize_statistic(stat) for stat in plot.statistics}
    out["coord"] = Coord.serialize_coordinate(plot.coord)
    out["guides"] = {Guide.serialize_guide(guide) for guide in plot.guides}
    out["mapping"] = serialize_mapping(plot.mapping)

    if with_data
        # TODO: In the future we may want to serialize the actual data frame
        # and let the user modify the data within the browser.
        error("Seralizing data_source not yet implemented.")
    else
        out["data_source"] = {"type" => "Ref",
                              "value" => @sprintf("%x", object_id(plot.data_source))}
    end

    # TODO: omitting theme for now. In the future we may want to serialize
    # this to allow the client to change the appearance.

    out
end


# Deserialize a Plot object.
function deserialize(::Type{Plot}, data::Dict)
    out = Plot()
    out.scales = ScaleElement[Scale.deserialize_scale(scale_data)
                              for scale_data in data["scales"]]
    out.statistics =  StatisticElement[Stat.deserialize_statistic(stat_data)
                                       for stat_data in data["statistics"]]
    out.coord = Coord.deserialize_coordinate(data["coord"])
    out.guides = GuideElement[Guide.deserialize_guide(guide_data)
                              for guide_data in data["guides"]]
    out.mapping = deserialize_mapping(data["mapping"])
    if data["data_source"]["type"] == "Ref"
        out.data_source = DATA_INDEX[parseint(Uint64, data["data_source"]["value"], 16)]
    end

    build_plot_data(out)

    for layer_data in data["layers"]
        layer = deserialize(Layer, layer_data)
        if layer.data_source === out.data_source && layer.mapping == out.mapping
            layer.data = out.data
        else
            layer.data = Data()
            for (k, v) in layer.mapping
                setfield(layer.data, k, eval_plot_mapping(layer.data_source, v))
            end
        end
        push!(out.layers, layer)
    end

    out
end


# We don't bother serializing layer.mapping or layer.data_source, since these
# are used only for construction. Once the layer is added to a plot, they become irrelevent.
#
# Args:
#   with_data: Serialize the literal data, rather than just a reference.
#
# Returns:
#  A simple dict/array serialization of the Layer.
#
function serialize(layer::Layer; with_data=false)
    out = Dict()
    if with_data
        error("Seralizing data_source not yet implemented.")
    else
        out["data_source"] = {"type"  => "Ref",
                              "value" => @sprintf("%x", (object_id(layer.data_source)))}
    end
    out["mapping"] = serialize_mapping(layer.mapping)
    out["statistic"] = Stat.serialize_statistic(layer.statistic)
    out["geom"] = Geom.serialize_geometry(layer.geom)
    out
end


# Deserialize a Layer object
function deserialize(::Type{Layer}, data::Dict)
    layer = Layer()
    if data["data_source"]["type"] == "Ref"
        layer.data_source = DATA_INDEX[parseint(Uint64, data["data_source"]["value"], 16)]
    end
    layer.mapping = deserialize_mapping(data["mapping"])
    layer.statistic = Stat.deserialize_statistic(data["statistic"])
    layer.geom = Geom.deserialize_geometry(data["geom"])
    layer
end


# Serialize aesthetics mappings
function serialize_mapping(mapping::Dict)
    out = Dict()
    for (k, v) in mapping
        if typeof(v) <: String || typeof(v) == Symbol
            out[string(k)] = {"type" => "String", "value" => string(v)}
        elseif typeof(v) <: Integer
            out[string(k)] = {"type" => "Int", "value" => v}
        elseif typeof(v) == Expr
            out[string(k)] = {"type" => "Expr", "value" => string(v)}
        else
            warn("Unable to serialize mapping of type $(typeof(v))")
        end
    end
    out
end


# Deserrialize aesthetics mappings
function deserialize_mapping(data::Dict)
    out = Dict()
    for (k, v) in data
        t = v["type"]
        if t == "String"
            out[symbol(k)] = v["value"]
        elseif t == "Int"
            out[symbol(k)] = v["value"] 
        elseif t == "Expr"
            out[symbol(k)] = parse(v["value"])
        else
            warn("Unable to deserialize mapping of type $(t)")
        end
    end
    out
end


include("webshow.jl")

end # module Gadfly
