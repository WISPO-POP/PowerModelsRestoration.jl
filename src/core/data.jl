"Set damage status for damaged_items in nw_data"
function damaged_items!(nw_data::Dict{String, Any}, damaged_items::Dict{String, Any})

    for id in keys(damaged_items)
        if haskey(nw_data, "nw")
            for network in nw_data["nw"]
                for i in damaged_items[id]
                    nw_data[id][i]["damaged"] = 1
                end
            end
        else
            for i in damaged_items[id]
                nw_data[id][i]["damaged"] = 1
            end
        end
    end
end


"Replace NaN and Nothing with 0 in multinetwork solutions"
function clean_solution!(solution)
    for item_type in ["gen", "storage", "branch","load","shunt"]
        if haskey(solution["solution"], "nw")
            for (n, net) in solution["solution"]["nw"]
                for (i,item) in get(net, item_type, Dict())
                    for k in keys(item)
                        if item[k] === nothing
                            item[k] = 0
                        elseif isnan(item[k])
                            item[k] = 0
                        end
                    end
                end
            end
        else
            for (i,item) in get(solution["solution"], item_type, Dict())
                for k in keys(item)
                    if item[k] === nothing
                        item[k] = 0
                    elseif isnan(item[k])
                        item[k] = 0
                    end
                end
            end
        end
    end
end


# Required because PowerModels assumes integral status values
"Replace non-integer status codes for devices, maps bus status to bus_type"
function clean_status!(data)
    if InfrastructureModels.ismultinetwork(data)
        for (i, nw_data) in data["nw"]
            _clean_status!(nw_data)
        end
    else
        _clean_status!(data)
    end
end

function _clean_status!(network)
    for (i, bus) in get(network, "bus", Dict())
        if haskey(bus, "status")
            status = round(Int, bus["status"])
            if status == 0
                bus["bus_type"] = 4
            elseif status == 1
                if bus["bus_type"] == 4
                    Memento.warn(_PMs._LOGGER, "bus $(i) given status 1 but the bus_type is 4")
                end
            else
                @assert false
            end
        end
    end

    for (comp_name, status_key) in _PMs.pm_component_status
        for (i, comp) in get(network, comp_name, Dict())
            if haskey(comp, status_key)
                comp[status_key] = round(Int, comp[status_key])
            end
        end
    end
end


"Transforms a single network into a multinetwork with several deepcopies of the original network. Indexed from 0."
function replicate_restoration_network(sn_data::Dict{String,<:Any}; count::Int=1, global_keys::Set{String}=Set{String}())
    return replicate_restoration_network(sn_data, count, union(global_keys, _PMs._pm_global_keys))
end


"Transforms a single network into a multinetwork with several deepcopies of the original network. Indexed from 0."
function replicate_restoration_network(sn_data::Dict{String,<:Any}, count::Int, global_keys::Set{String})
    @assert count > 0
    if _IMs.ismultinetwork(sn_data)
        Memento.error(_PMs._LOGGER, "replicate_restoration_network can only be used on single networks")
    end

    propagate_damage_status!(sn_data)

    name = get(sn_data, "name", "anonymous")

    mn_data = Dict{String,Any}(
        "nw" => Dict{String,Any}()
    )

    mn_data["multinetwork"] = true

    sn_data_tmp = deepcopy(sn_data)
    for k in global_keys
        if haskey(sn_data_tmp, k)
            mn_data[k] = sn_data_tmp[k]
        end

        # note this is robust to cases where k is not present in sn_data_tmp
        delete!(sn_data_tmp, k)
    end

    item_dict = Dict("gen"=>"gen_status", "branch"=>"br_status", "storage"=>"status", "bus"=>"bus_type")
    total_repairs = 0
    for (j, st) in item_dict
        for (i,item) in sn_data[j]
            if j=="bus"
                total_repairs += (get(item,"damaged",0)==1 && get(item,st,1 )!= 4) ? 1 : 0
            else
                total_repairs += get(item,"damaged",0)*get(item,st,0)
            end
        end
    end

    if count >= total_repairs
        Memento.warn(_PMs._LOGGER, "More restoration steps than damaged components.  Reducing restoration steps to $(total_repairs).")
        count = total_repairs
    end

    mn_data["name"] = "$(count) period restoration of $(name)"

    for n in 0:count
        mn_data["nw"]["$n"] = deepcopy(sn_data_tmp)
    end

    repairs_per_period = total_repairs/count

    mn_data["nw"]["0"]["repairs"] = 0
    mn_data["nw"]["0"]["repaired_total"] = 0
    
    for n in 1:count
        if repairs_per_period*(n) < total_repairs 
            mn_data["nw"]["$n"]["repairs"] = trunc(Int,round(repairs_per_period*n - mn_data["nw"]["$(n-1)"]["repaired_total"]))
        else
            mn_data["nw"]["$n"]["repairs"] = total_repairs - mn_data["nw"]["$(n-1)"]["repaired_total"]
        end

        mn_data["nw"]["$(n-1)"]["time_elapsed"] = mn_data["nw"]["$n"]["repairs"] * get(mn_data["nw"]["$(n-1)"], "time_elapsed", 1.0)
        mn_data["nw"]["$n"]["repaired_total"] = sum(mn_data["nw"]["$(nw)"]["repairs"] for nw=0:n)
    end
    mn_data["nw"]["$(count)"]["time_elapsed"] = get(mn_data["nw"]["$(count)"], "time_elapsed", 1.0)

    return mn_data
end

""
function propagate_damage_status!(data::Dict{String,<:Any})
    if InfrastructureModels.ismultinetwork(data)
        for (i,nw_data) in data["nw"]
            _propagate_damage_status!(nw_data)
        end
    else
        _propagate_damage_status!(data)
    end
end


""
function _propagate_damage_status!(data::Dict{String,<:Any})
    buses = Dict(bus["bus_i"] => bus for (i,bus) in data["bus"])

    incident_gen = _PMs.bus_gen_lookup(data["gen"], data["bus"])
    incident_active_gen = Dict()
    for (i, gen_list) in incident_gen
        incident_active_gen[i] = [gen for gen in gen_list if ~haskey(gen, "damaged") || gen["damaged"] == 0]
    end

    incident_storage = _PMs.bus_storage_lookup(data["storage"], data["bus"])
    incident_active_storage = Dict()
    for (i, storage_list) in incident_storage
        incident_active_storage[i] = [gen for gen in storage_list if ~haskey(gen, "damaged") || gen["damaged"] == 0]
    end

    incident_branch = Dict(bus["bus_i"] => [] for (i,bus) in data["bus"])
    for (i,branch) in data["branch"]
        push!(incident_branch[branch["f_bus"]], branch)
        push!(incident_branch[branch["t_bus"]], branch)
    end

    updated = true
    iteration = 0

    for (i,branch) in data["branch"]
        if ~haskey(branch, "damaged") || branch["damaged"] != 1
            f_bus = buses[branch["f_bus"]]
            t_bus = buses[branch["t_bus"]]

            if (haskey(f_bus, "damaged") && f_bus["damaged"]) == 1 || (haskey(t_bus, "damaged") && t_bus["damaged"]) == 1
                Memento.info(_PMs._LOGGER, "deactivating branch $(i):($(branch["f_bus"]),$(branch["t_bus"])) due to damaged connecting bus")
                branch["damaged"] = 1
                updated = true
            end
        end
    end

    for (i,bus) in buses
        if haskey(bus, "damaged") && bus["damaged"] == 1
            for gen in incident_active_gen[i]
                Memento.info(_PMs._LOGGER, "deactivating generator $(gen["index"]) due to damaged bus $(i)")
                gen["damaged"] = 1
                updated = true
            end
        end
    end

    for (i,bus) in buses
        if haskey(bus, "damaged") && bus["damaged"] == 1
            for storage in incident_active_storage[i]
                Memento.info(_PMs._LOGGER, "deactivating storage $(storage["index"]) due to damaged bus $(i)")
                storage["damaged"] = 1
                updated = true
            end
        end
    end
end


