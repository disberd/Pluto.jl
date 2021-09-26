module SessionActions

import ..Pluto: ServerSession, Notebook, Cell, emptynotebook, tamepath, new_notebooks_directory, without_pluto_file_extension, numbered_until_new, readwrite, update_save_run!, update_from_file, wait_until_file_unchanged, putnotebookupdates!, putplutoupdates!, load_notebook, clientupdate_notebook_list, WorkspaceManager, @asynclog
using FileWatching

struct NotebookIsRunningException <: Exception
    notebook::Notebook
end

abstract type AbstractUserError <: Exception end
struct UserError <: AbstractUserError
    msg::String
end
function Base.showerror(io::IO, e::UserError)
    print(io, e.msg)
end

function open_url(session::ServerSession, url::AbstractString; kwargs...)
    path = download(url, emptynotebook().path)
    open(session, path; kwargs...)
end

function open(session::ServerSession, path::AbstractString; run_async=true, compiler_options=nothing, as_sample=false)
    if as_sample
        new_filename = "sample " * without_pluto_file_extension(basename(path))
        new_path = numbered_until_new(joinpath(new_notebooks_directory(), new_filename); suffix=".jl")
        
        readwrite(path, new_path)
        path = new_path
    end

    for nb in values(session.notebooks)
        if realpath(nb.path) == realpath(tamepath(path))
            throw(NotebookIsRunningException(nb))
        end
    end
    
    nb = load_notebook(tamepath(path); disable_writing_notebook_files=session.options.server.disable_writing_notebook_files)

    # overwrites the notebook environment if specified
    if compiler_options !== nothing
        nb.compiler_options = compiler_options
    end

    session.notebooks[nb.notebook_id] = nb
    if session.options.evaluation.run_notebook_on_load
        for c in nb.cells
            c.queued = true
        end
        update_save_run!(session, nb, nb.cells; run_async=run_async, prerender_text=true)
    end
    
    add(session, nb; run_async=run_async)

    nb
end

function add(session::ServerSession, nb::Notebook; run_async::Bool=true)
    session.notebooks[nb.notebook_id] = nb
    
    if run_async
        @asynclog putplutoupdates!(session, clientupdate_notebook_list(session.notebooks))
    else
        putplutoupdates!(session, clientupdate_notebook_list(session.notebooks))
    end
    
    
    running = Ref(false)
    function update_from_file_throttled()
        if !running[]
            running[] = true
            
            @info "Updating from file..."
            
            
		    sleep(1.2 - .5) ## There seems to be a synchronization issue if your OS is VERYFAST
            wait_until_file_unchanged(nb.path, .5)
            update_from_file(session, nb)
            
            @info "Updating from file done!"
            
            running[] = false
        end
    end

    session.options.server.auto_reload_from_file && @asynclog while true
        if !isfile(nb.path)
            # notebook file deleted... let's ignore this, changing the notebook will cause it to save again. Fine for now
            sleep(2)
        else
            watch_file(nb.path)
            current_time = time()
            @info "File changed" (current_time - nb.last_save_time)
            if current_time - nb.last_save_time < 2.0
                @info "Notebook was saved by me very recently, not reloading from file."
            else
                update_from_file_throttled()
            end
        end
    end
    
    nb
end

function save_upload(content::Vector{UInt8})
    save_path = emptynotebook().path
    Base.open(save_path, "w") do io
        write(io, content)
    end

    save_path
end

function new(session::ServerSession; run_async=true)
    nb = if session.options.server.init_with_file_viewer
        
        @warn "DEPRECATED: init_with_file_viewer will be removed soon."
        
        file_viewer_code = """html\"\"\"

        <script>

        const nbfile_url = window.location.href.replace("edit", "notebookfile")


        const pre = html`<pre style="font-size: .6rem;">Loading...</pre>`

        const handle = setInterval(async () => {

        pre.innerText = await (await fetch(nbfile_url)).text()
        }, 500)

        invalidation.then(() => {
        clearInterval(handle)
        })

        return pre

        </script>

        \"\"\"
        """
        Notebook([Cell(), Cell(code=file_viewer_code, code_folded=true)])

    else
        emptynotebook()
    end
    update_save_run!(session, nb, nb.cells; run_async=run_async, prerender_text=true)
    
    add(session, nb; run_async=run_async)

    nb
end

function shutdown(session::ServerSession, notebook::Notebook; keep_in_session=false, async=false)
    notebook.nbpkg_restart_recommended_msg = nothing
    notebook.nbpkg_restart_required_msg = nothing

    if !keep_in_session
        listeners = putnotebookupdates!(session, notebook) # TODO: shutdown message
        delete!(session.notebooks, notebook.notebook_id)
        putplutoupdates!(session, clientupdate_notebook_list(session.notebooks))
        for client in listeners
            @async close(client.stream)
        end
    end
    WorkspaceManager.unmake_workspace((session, notebook); async=async)
end

end