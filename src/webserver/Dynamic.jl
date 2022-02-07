import UUIDs: uuid1

import .PkgCompat

"Will hold all 'response handlers': functions that respond to a WebSocket request from the client."
const responses = Dict{Symbol,Function}()

Base.@kwdef struct ClientRequest
    session::ServerSession
    notebook::Union{Nothing,Notebook}
    body::Any=nothing
    initiator::Union{Initiator,Nothing}=nothing
end

require_notebook(r::ClientRequest) = if r.notebook === nothing
    throw(ArgumentError("Notebook request called without a notebook 😗"))
end


###
# RESPONDING TO A NOTEBOOK STATE UPDATE
###

"""
## State management in Pluto

*Aka: how do the server and clients stay in sync?*



A Pluto notebook session has *state*: with this, we mean:

1. The input and ouput of each cell, the cell order, and more metadata about the notebook and cells [^state]

This state needs to be **synchronised between the server and all clients** (we support multiple synchronised clients), and note that:

- Either side wants to update the state. Generally, a client will update cell inputs, the server will update cell outputs.
- Both sides want to *react* to state updates
- The server is in Julia, the clients are in JS
- This is built on top of our websocket+msgpack connection, but that doesn't matter too much

We do this by implementing something similar to how you use Google Firebase: there is **one shared state object, any party can mutate it, and it will synchronise to all others automatically**. The state object is a nested structure of mutable `Dict`s, with immutable ints, strings, bools, arrays, etc at the endpoints.



Some cool things are:

- Our system uses object diffing, so only *changes to the state* are actually tranferred over the network. But you can use it as if the entire state is sent around constantly.
- In the frontend, the *shared state* is part of the *react state*, i.e. shared state updates automatically trigger visual updates.
- Within the client, state changes take effect instantly, without waiting for a round trip to the server. This means that when you add a cell, it shows up instantly.

Diffing is done using `immer.js` (frontend) and `src/webserver/Firebasey.jl` (server). We wrote Firebasey ourselves to match immer's functionality, and the cool thing is: **it is a Pluto notebook**! Since Pluto notebooks are `.jl` files, we can just `include` it in our module.

The shared state object is generated by [`notebook_to_js`](@ref). Take a look! The Julia server orchestrates this firebasey stuff. For this, we keep a **copy** of the latest state of each client on the server (see [`current_state_for_clients`](@ref)). When anything changes to the Julia state (e.g. when a cell finished running), we call [`send_notebook_changes!`](@ref), which will call [`notebook_to_js`](@ref) to compute the new desired state object. For each client, we diff the new state to their last known state, and send them the difference.



### Responding to changes made by a client

When a client updates the shared state object, we want the server to *react* to that change by taking an action. Which action to take depends on which field changes. For example, when `state["path"]` changes, we should rename the notebook file. When `state["cell_inputs"][a_cell_id]["code"]` changes, we should reparse and analyze that cel, etc. This location of the change, e.g.  `"cell_inputs/<a_cell_id>/code"` is called the *path* of the change.

[`effects_of_changed_state`](@ref) define these pattern-matchers. We use a `Wildcard()` to take the place of *any* key, see [`Wildcard`](@ref), and we use the change/update/patch inside the given function.



### Not everything uses the shared state (yet)

Besides `:update_notebook`, you will find more functions in [`responses`](@ref) that respond to classic 'client requests', such as `:reshow_cell` and `:shutdown_notebook`. Some of these requests get a direct response, like the list of autocomplete options to a `:complete` request (in `src/webserver/REPLTools.jl`). On the javascript side, these direct responses can be `awaited`, because every message has a unique ID.



[^state]:
    Two other meanings of _state_ could be:
    2. The reactivity data: the parsed AST (`Expr`) of each cell, which variables are defined or referenced by which cells, in what order will cells run?
    3. The state of the Julia process: i.e. which variables are defined, which packages are imported, etc.
    
    The first two (1 & 2) are stored in a [`Notebook`](@ref) struct, remembered by the server process (Julia). (In fact, (2) is entirely described by (1), but we store it for performance reasons.) I included (3) for completeness, but it is not stored by us, we hope to control and minimize (3) by keeping track of (1) and (2).

"""
module Firebasey include("./Firebasey.jl") end
module AppendonlyMarkers
    # I put Firebasey here manually THANKS JULIA
    import ..Firebasey
    include("./AppendonlyMarkers.jl")
end

# All of the arrays in the notebook_to_js object are 'immutable' (we write code as if they are), so we can enable this optimization:
Firebasey.use_triple_equals_for_arrays[] = true

# the only possible Arrays are:
# - cell_order
# - cell_execution_order
# - cell_result > * > output > body
# - bonds > * > value > *
# - cell_dependencies > * > downstream_cells_map > * > 
# - cell_dependencies > * > upstream_cells_map > * > 

function notebook_to_js(notebook::Notebook)
    Dict{String,Any}(
        "notebook_id" => notebook.notebook_id,
        "path" => notebook.path,
        "in_temp_dir" => startswith(notebook.path, new_notebooks_directory()),
        "shortpath" => basename(notebook.path),
        "process_status" => notebook.process_status,
        "last_save_time" => notebook.last_save_time,
        "last_hot_reload_time" => notebook.last_hot_reload_time,
        "cell_inputs" => Dict{UUID,Dict{String,Any}}(
            id => Dict{String,Any}(
                "cell_id" => cell.cell_id,
                "code" => cell.code,
                "code_folded" => cell.code_folded,
                "running_disabled" => cell.running_disabled,
                "notebook_exclusive" => cell.notebook_exclusive,
            )
        for (id, cell) in notebook.cells_dict),
        "cell_dependencies" => Dict{UUID,Dict{String,Any}}(
            id => Dict{String,Any}(
                "cell_id" => cell.cell_id,
                "downstream_cells_map" => Dict{String,Vector{UUID}}(
                    String(s) => cell_id.(r)
                    for (s, r) in cell.cell_dependencies.downstream_cells_map
                ),
                "upstream_cells_map" => Dict{String,Vector{UUID}}(
                    String(s) => cell_id.(r)
                    for (s, r) in cell.cell_dependencies.upstream_cells_map
                ),
                "precedence_heuristic" => cell.cell_dependencies.precedence_heuristic,
            )
        for (id, cell) in notebook.cells_dict),
        "cell_results" => Dict{UUID,Dict{String,Any}}(
            id => Dict{String,Any}(
                "cell_id" => cell.cell_id,
                "depends_on_disabled_cells" => cell.depends_on_disabled_cells,
                "output" => Dict(                
                    "body" => cell.output.body,
                    "mime" => cell.output.mime,
                    "rootassignee" => cell.output.rootassignee,
                    "last_run_timestamp" => cell.output.last_run_timestamp,
                    "persist_js_state" => cell.output.persist_js_state,
                    "has_pluto_hook_features" => cell.output.has_pluto_hook_features,
                ),
                "published_object_keys" => keys(cell.published_objects),
                "queued" => cell.queued,
                "running" => cell.running,
                "errored" => cell.errored,
                "runtime" => cell.runtime,
                "logs" => AppendonlyMarkers.AppendonlyMarker(cell.logs),
            )
        for (id, cell) in notebook.cells_dict),
        "cell_order" => notebook.cell_order,
        "published_objects" => merge!(Dict{String,Any}(), (c.published_objects for c in values(notebook.cells_dict))...),
        "bonds" => Dict{String,Dict{String,Any}}(
            String(key) => Dict(
                "value" => bondvalue.value, 
            )
        for (key, bondvalue) in notebook.bonds),
        "nbpkg" => let
            ctx = notebook.nbpkg_ctx
            Dict{String,Any}(
                "enabled" => ctx !== nothing,
                "restart_recommended_msg" => notebook.nbpkg_restart_recommended_msg,
                "restart_required_msg" => notebook.nbpkg_restart_required_msg,
                # TODO: cache this
                "installed_versions" => ctx === nothing ? Dict{String,String}() : notebook.nbpkg_installed_versions_cache,
                "terminal_outputs" => notebook.nbpkg_terminal_outputs,
                "busy_packages" => notebook.nbpkg_busy_packages,
                "instantiated" => notebook.nbpkg_ctx_instantiated,
            )
        end,
        "cell_execution_order" => cell_id.(collect(topological_order(notebook))),
    )
end

"""
For each connected client, we keep a copy of their current state. This way we know exactly which updates to send when the server-side state changes.
"""
const current_state_for_clients = WeakKeyDict{ClientSession,Any}()

"""
Update the local state of all clients connected to this notebook.
"""
function send_notebook_changes!(🙋::ClientRequest; commentary::Any=nothing)
    notebook_dict = notebook_to_js(🙋.notebook)
    for (_, client) in 🙋.session.connected_clients
        if client.connected_notebook !== nothing && client.connected_notebook.notebook_id == 🙋.notebook.notebook_id
            current_dict = get(current_state_for_clients, client, :empty)
            patches = Firebasey.diff(current_dict, notebook_dict)
            patches_as_dicts::Array{Dict} = patches
            current_state_for_clients[client] = deep_enough_copy(notebook_dict)

            # Make sure we do send a confirmation to the client who made the request, even without changes
            is_response = 🙋.initiator !== nothing && client == 🙋.initiator.client

            if !isempty(patches) || is_response
                response = Dict(
                    :patches => patches_as_dicts,
                    :response => is_response ? commentary : nothing
                )
                putclientupdates!(client, UpdateMessage(:notebook_diff, response, 🙋.notebook, nothing, 🙋.initiator))
            end
        end
    end
    try_event_call(🙋.session, FileEditEvent(🙋.notebook))
end

"Like `deepcopy`, but anything onther than `Dict` gets a shallow (reference) copy."
function deep_enough_copy(d::Dict{A,B}) where {A, B}
    Dict{A,B}(
        k => deep_enough_copy(v)
        for (k, v) in d
    )
end
deep_enough_copy(x) = x

"""
A placeholder path. The path elements that it replaced will be given to the function as arguments.
"""
struct Wildcard end

abstract type Changed end
struct CodeChanged <: Changed end
struct FileChanged <: Changed end
struct BondChanged <: Changed
    bond_name::Symbol
    is_first_value::Bool
end

# to support push!(x, y...) # with y = []
Base.push!(x::Set{Changed}) = x

const no_changes = Changed[]


const effects_of_changed_state = Dict(
    "path" => function(; request::ClientRequest, patch::Firebasey.ReplacePatch)
        newpath = tamepath(patch.value)
        # SessionActions.move(request.session, request.notebook, newpath)

        if isfile(newpath)
            error("File exists already - you need to delete the old file manually.")
        else
            move_notebook!(request.notebook, newpath; disable_writing_notebook_files=request.session.options.server.disable_writing_notebook_files)
            putplutoupdates!(request.session, clientupdate_notebook_list(request.session.notebooks))
            WorkspaceManager.cd_workspace((request.session, request.notebook), newpath)
        end
        return no_changes
    end,
    "process_status" => function(; request::ClientRequest, patch::Firebasey.ReplacePatch)
        newstatus = patch.value

        @info "Process status set by client" newstatus
    end,
    "in_temp_dir" => function(; _...) no_changes end,
    "cell_inputs" => Dict(
        Wildcard() => function(cell_id, rest...; request::ClientRequest, patch::Firebasey.JSONPatch)
            Firebasey.applypatch!(request.notebook, patch)

            if length(rest) == 0
                [CodeChanged(), FileChanged()]
            elseif length(rest) == 1 && Symbol(rest[1]) == :code
                [CodeChanged(), FileChanged()]
            else
                [FileChanged()]
            end
        end,
    ),
    "cell_order" => function(; request::ClientRequest, patch::Firebasey.ReplacePatch)
        Firebasey.applypatch!(request.notebook, patch)
        [FileChanged()]
    end,
    "bonds" => Dict(
        Wildcard() => function(name; request::ClientRequest, patch::Firebasey.JSONPatch)
            name = Symbol(name)
            Firebasey.applypatch!(request.notebook, patch)
            [BondChanged(name, patch isa Firebasey.AddPatch)]
        end,
    )
)


responses[:update_notebook] = function response_update_notebook(🙋::ClientRequest)
    require_notebook(🙋)
    try
        notebook = 🙋.notebook
        patches = (Base.convert(Firebasey.JSONPatch, update) for update in 🙋.body["updates"])

        if length(patches) == 0
            send_notebook_changes!(🙋)
            return nothing
        end

        if !haskey(current_state_for_clients, 🙋.initiator.client)
            throw(ErrorException("Updating without having a first version of the notebook??"))
        end

        # TODO Immutable ??
        for patch in patches
            Firebasey.applypatch!(current_state_for_clients[🙋.initiator.client], patch)
        end

        changes = Set{Changed}()

        for patch in patches
            (mutator, matches, rest) = trigger_resolver(effects_of_changed_state, patch.path)
            
            current_changes = if isempty(rest) && applicable(mutator, matches...)
                mutator(matches...; request=🙋, patch)
            else
                mutator(matches..., rest...; request=🙋, patch)
            end

            push!(changes, current_changes...)
        end

        # If CodeChanged ∈ changes, then the client will also send a request like run_multiple_cells, which will trigger a file save _before_ running the cells.
        # In the future, we should get rid of that request, and save the file here. For now, we don't save the file here, to prevent unnecessary file IO.
        # (You can put a log in save_notebook to track how often the file is saved)
        if FileChanged() ∈ changes && CodeChanged() ∉ changes
             save_notebook(🙋.session, notebook)
        end

        let bond_changes = filter(x -> x isa BondChanged, changes)
            bound_sym_names = Symbol[x.bond_name for x in bond_changes]
            is_first_values = Bool[x.is_first_value for x in bond_changes]
            set_bond_values_reactive(;
                session=🙋.session,
                notebook=🙋.notebook,
                bound_sym_names=bound_sym_names,
                is_first_values=is_first_values,
                run_async=true,
                initiator=🙋.initiator,
            )
        end
    
        send_notebook_changes!(🙋; commentary=Dict(:update_went_well => :👍))
    catch ex
        @error "Update notebook failed"  🙋.body["updates"] exception=(ex, stacktrace(catch_backtrace()))
        response = Dict(
            :update_went_well => :👎,
            :why_not => sprint(showerror, ex),
            :should_i_tell_the_user => ex isa SessionActions.UserError,
        )
        send_notebook_changes!(🙋; commentary=response)
    end
end

function trigger_resolver(anything, path, values=[])
	(value=anything, matches=values, rest=path)
end
function trigger_resolver(resolvers::Dict, path, values=[])
	if isempty(path)
		throw(BoundsError("resolver path ends at Dict with keys $(keys(resolver))"))
	end
	
	segment = first(path)
	rest = path[firstindex(path)+1:end]
	for (key, resolver) in resolvers
		if key isa Wildcard
			continue
		end
		if key == segment
			return trigger_resolver(resolver, rest, values)
		end
	end
	
	if haskey(resolvers, Wildcard())
		return trigger_resolver(resolvers[Wildcard()], rest, (values..., segment))
    else
        throw(BoundsError("failed to match path $(path), possible keys $(keys(resolver))"))
	end
end




###
# MISC RESPONSES
###

responses[:connect] = function response_connect(🙋::ClientRequest)
    putclientupdates!(🙋.session, 🙋.initiator, UpdateMessage(:👋, Dict(
        :notebook_exists => (🙋.notebook !== nothing),
        :options => 🙋.session.options,
        :version_info => Dict(
            :pluto => PLUTO_VERSION_STR,
            :julia => JULIA_VERSION_STR,
            :dismiss_update_notification => 🙋.session.options.server.dismiss_update_notification,
        ),
    ), nothing, nothing, 🙋.initiator))
end

responses[:ping] = function response_ping(🙋::ClientRequest)
    putclientupdates!(🙋.session, 🙋.initiator, UpdateMessage(:pong, Dict(), nothing, nothing, 🙋.initiator))
end

responses[:reset_shared_state] = function response_reset_shared_state(🙋::ClientRequest)
    delete!(current_state_for_clients, 🙋.initiator.client)
    send_notebook_changes!(🙋; commentary=Dict(:from_reset =>  true))
end

responses[:run_multiple_cells] = function response_run_multiple_cells(🙋::ClientRequest)
    require_notebook(🙋)
    uuids = UUID.(🙋.body["cells"])
    cells = map(uuids) do uuid
        🙋.notebook.cells_dict[uuid]
    end

    if will_run_code(🙋.notebook)
        foreach(c -> c.queued = true, cells)
        send_notebook_changes!(🙋)
    end
    
    # save=true fixes the issue where "Submit all changes" or `Ctrl+S` has no effect.
    update_save_run!(🙋.session, 🙋.notebook, cells; run_async=true, save=true)
end

responses[:get_all_notebooks] = function response_get_all_notebooks(🙋::ClientRequest)
    putplutoupdates!(🙋.session, clientupdate_notebook_list(🙋.session.notebooks, initiator=🙋.initiator))
end

responses[:interrupt_all] = function response_interrupt_all(🙋::ClientRequest)
    require_notebook(🙋)

    session_notebook = (🙋.session, 🙋.notebook)
    workspace = WorkspaceManager.get_workspace(session_notebook)

    already_interrupting = 🙋.notebook.wants_to_interrupt
    anything_running = !isready(workspace.dowork_token)
    if !already_interrupting && anything_running
        🙋.notebook.wants_to_interrupt = true
        WorkspaceManager.interrupt_workspace(session_notebook)
    end
    # TODO: notify user whether interrupt was successful
end

responses[:shutdown_notebook] = function response_shutdown_notebook(🙋::ClientRequest)
    require_notebook(🙋)
    SessionActions.shutdown(🙋.session, 🙋.notebook; keep_in_session=🙋.body["keep_in_session"])
end

without_initiator(🙋::ClientRequest) = ClientRequest(session=🙋.session, notebook=🙋.notebook)

responses[:restart_process] = function response_restart_process(🙋::ClientRequest; run_async::Bool=true)
    require_notebook(🙋)

    
    if 🙋.notebook.process_status != ProcessStatus.waiting_to_restart
        🙋.notebook.process_status = ProcessStatus.waiting_to_restart
        send_notebook_changes!(🙋 |> without_initiator)

        SessionActions.shutdown(🙋.session, 🙋.notebook; keep_in_session=true, async=true)

        🙋.notebook.process_status = ProcessStatus.starting
        send_notebook_changes!(🙋 |> without_initiator)

        update_save_run!(🙋.session, 🙋.notebook, 🙋.notebook.cells; run_async=run_async, save=true)
    end
end


responses[:reshow_cell] = function response_reshow_cell(🙋::ClientRequest)
    require_notebook(🙋)
    cell = let
        cell_id = UUID(🙋.body["cell_id"])
        🙋.notebook.cells_dict[cell_id]
    end
    run = WorkspaceManager.format_fetch_in_workspace(
        (🙋.session, 🙋.notebook), 
        cell.cell_id, 
        ends_with_semicolon(cell.code), 
        collect(keys(cell.published_objects)),
        (parse(PlutoRunner.ObjectID, 🙋.body["objectid"], base=16), convert(Int64, 🙋.body["dim"])),
    )
    set_output!(cell, run, ExprAnalysisCache(🙋.notebook, cell); persist_js_state=true)
    # send to all clients, why not
    send_notebook_changes!(🙋 |> without_initiator)
end

responses[:nbpkg_available_versions] = function response_nbpkg_available_versions(🙋::ClientRequest)
    # require_notebook(🙋)
    all_versions = PkgCompat.package_versions(🙋.body["package_name"])
    putclientupdates!(🙋.session, 🙋.initiator, UpdateMessage(:🍕, Dict(
        :versions => string.(all_versions),
    ), nothing, nothing, 🙋.initiator))
end

responses[:package_completions] = function response_package_completions(🙋::ClientRequest)
    results = PkgCompat.package_completions(🙋.body["query"])
    putclientupdates!(🙋.session, 🙋.initiator, UpdateMessage(:🍳, Dict(
        :results => results,
    ), nothing, nothing, 🙋.initiator))
end

responses[:pkg_update] = function response_pkg_update(🙋::ClientRequest)
    require_notebook(🙋)
    update_nbpkg(🙋.session, 🙋.notebook)
    putclientupdates!(🙋.session, 🙋.initiator, UpdateMessage(:🦆, Dict(), nothing, nothing, 🙋.initiator))
end
