# One-process, read-only snapshot. No lock, property mutation or module repair.
function line(path, value, rc) { rc=(getline value < path); close(path); return rc>0 ? value : "" }
function kv(path, row, at) {
    while((getline row < path)>0) {at=index(row,"=");if(at) state[path,substr(row,1,at-1)]=substr(row,at+1)}
    close(path)
}
function value(file,key) {return state[root "/" file,key]}
function quote(s, i,c,out) {
    out="\""
    for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c=="\"")out=out "\\\"";else if(c=="\\")out=out "\\\\";else if(c=="\n")out=out "\\n";else if(c=="\r")out=out "\\r";else if(c=="\t")out=out "\\t";else if(c ~ /[[:cntrl:]]/)out=out "?";else out=out c}
    return out "\""
}
function number(s) {return s ~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/ ? sprintf("%.0f",s) : "null"}
function put(key,val,type) {if(count++)printf ",";printf "%s:",quote(key);if(type=="raw")printf "%s",val;else if(type=="num")printf "%s",number(val);else printf "%s",quote(val)}
function params(file, prefix, sw,mfk,wsf,vcp) {
    sw=value(file,"swappiness");mfk=value(file,"min_free_kbytes");wsf=value(file,"watermark_scale_factor");vcp=value(file,"vfs_cache_pressure")
    if(sw=="" || mfk=="" || wsf=="" || vcp=="")return "null"
    return "{\"swappiness\":" number(sw) ",\"min_free_kbytes\":" number(mfk) ",\"watermark_scale_factor\":" number(wsf) ",\"vfs_cache_pressure\":" number(vcp) "}"
}
function bytes(spec,pct) {if(spec ~ /^[0-9]+%$/){pct=substr(spec,1,length(spec)-1);return int(ram*pct/100/page)*page}return spec ~ /^[0-9]+$/ ? spec+0 : 0}
function read_pressure(row,parts,v){
    while((getline row < "/proc/pressure/memory")>0){split(row,parts," ");split(parts[2],v,"=");if(parts[1]=="some")some=v[2]+0;if(parts[1]=="full")full=v[2]+0}
    close("/proc/pressure/memory")
}
{
    row=$0;at=index(row,"]: [");if(at) prop[substr(row,2,at-2)]=substr(row,at+4,length(row)-at-4)
}
END {
    split(policy,limits," ")
    boot=line("/proc/sys/kernel/random/boot_id")
    page=pagesize+0;if(page<=0)page=prop["ro.boot.hardware.cpu.pagesize"]+0
    while((getline row < "/proc/meminfo")>0){split(row,parts,/[ \t]+/);mem[parts[1]]=parts[2]+0}close("/proc/meminfo")
    ram=mem["MemTotal:"]*1024;available=mem["MemAvailable:"]*1024
    swap_state="inactive";n=0
    while((getline row < "/proc/swaps")>0){split(row,parts,/[ \t]+/);if(parts[1]=="Filename")continue;n++;if(parts[1] ~ /(^|\/)zram0$/){swap_state="active";swap_size=parts[3];swap_used=parts[4]}}close("/proc/swaps")
    if(n==0 && mem["SwapTotal:"]>0)swap_state="unknown"
    sw=line("/proc/sys/vm/swappiness");mfk=line("/proc/sys/vm/min_free_kbytes");wsf=line("/proc/sys/vm/watermark_scale_factor");vcp=line("/proc/sys/vm/vfs_cache_pressure")
    size=line("/sys/block/zram0/disksize");algorithms=line("/sys/block/zram0/comp_algorithm");algorithm=algorithms;sub(/^.*\[/,"",algorithm);sub(/\].*$/,"",algorithm)
    raw=line("/sys/block/zram0/mm_stat");sub(/^[ \t]+/,"",raw);split(raw,mm,/[ \t]+/)
    raw=line("/sys/block/zram0/bd_stat");sub(/^[ \t]+/,"",raw);split(raw,bd,/[ \t]+/)
    raw=line("/sys/block/zram0/io_stat");sub(/^[ \t]+/,"",raw);split(raw,io,/[ \t]+/)
    kv(root "/.memory_original");kv(root "/.memory_runtime_vm");kv(root "/.memory_boot_config");kv(root "/.memory_boot_result");kv(root "/.memory_boot_baseline");kv(root "/.zram_runtime_state");kv(root "/.zram_runtime.lock/owner")
    original_ok=(value(".memory_original","fingerprint")==prop["ro.build.fingerprint"] && value(".memory_original","source")=="original_vendor_namespace")
    mode="system";feature="system";desired="null";drift="";vm_phase="observed"
    if(value(".memory_runtime_vm","boot_id")==boot && value(".memory_runtime_vm","fingerprint")==prop["ro.build.fingerprint"]){
        desired=params(".memory_runtime_vm")
        if(desired!="null"){
            if(sw!=value(".memory_runtime_vm","swappiness"))drift="\"swappiness\""
            if(mfk!=value(".memory_runtime_vm","min_free_kbytes"))drift=drift (drift!="" ? "," : "") "\"min_free_kbytes\""
            if(wsf!=value(".memory_runtime_vm","watermark_scale_factor"))drift=drift (drift!="" ? "," : "") "\"watermark_scale_factor\""
            if(vcp!=value(".memory_runtime_vm","vfs_cache_pressure"))drift=drift (drift!="" ? "," : "") "\"vfs_cache_pressure\""
            vm_phase=drift=="" ? "effective" : "drifted"
            source=value(".memory_runtime_vm","source");if(source!="restore"){mode=source=="preset" ? "preset" : "custom";feature="optimized"}
        }
    }
    phase=value(".zram_runtime_state","phase");if(phase=="")phase="none"
    operation_boot=value(".zram_runtime_state","boot_id");pending="false"
    if(operation_boot!="" && operation_boot!=boot)phase="historical"
    else if(phase ~ /^(queued|preflight|stopping_mmd|swapoff|rebuilding|verifying|rollback)$/){
        pid=value(".zram_runtime.lock/owner","pid");stat=line("/proc/" pid "/stat");sub(/^.*\) /,"",stat);split(stat,parts," ")
        if(value(".zram_runtime.lock/owner","boot_id")==boot && parts[20]==value(".zram_runtime.lock/owner","start_ticks") && parts[1]!="Z")pending="true"
        else{split(line("/proc/uptime"),parts," ");age=parts[1]-value(".zram_runtime_state","uptime");if(phase=="queued" && age>=0 && age<=30)pending="true";else phase="unconfirmed"}
    }
    if(phase=="success" && (swap_state!="active" || algorithm!=value(".zram_runtime_state","algorithm") || (size!=bytes(value(".zram_runtime_state","size")) && size!=bytes(value(".zram_runtime_state","size"))+page)))phase="external_changed"
    read_pressure()
    margin=ram/20;if(mfk*1024>margin)margin=mfk*1024;required=swap_used*1024+margin
    supported=(prop["ro.build.version.sdk"]>=37 && setup=="true" && prop["mmd.zram.enabled"]=="true" && prop["mmd.setup_complete"]=="true" && prop["init.svc.mmd"]=="running")
    online="false";reason="platform_setup_unavailable"
    if(supported){reason="unsupported_swap_layout";if(n==1 && swap_state=="active"){reason="writeback_history_present";if(bd[1]==0 && bd[2]==0 && bd[3]==0){reason="memory_pressure";if(full<1 && some<10){reason="insufficient_swapoff_headroom";if(available>=required){online="true";reason="ready"}}}}}
    printf "{"
    put("swappiness",sw,"num");put("min_free_kbytes",mfk,"num");put("watermark_scale_factor",wsf,"num");put("vfs_cache_pressure",vcp,"num")
    put("mode",mode);put("feature_vm",feature);put("vm_desired",desired,"raw");put("vm_drift_fields","[" drift "]","raw");put("vm_effective_state",vm_phase);put("vm_policy_ready",line(root "/.vm_policy_ready")=="true" ? "true" : "false","raw")
    put("zram_algo",algorithm);put("zram_disksize",size,"num");put("zram_active",swap_state=="active" ? "true" : "false","raw");put("zram_active_state",swap_state);put("zram_swap_kb",swap_used,"num");put("zram_swap_size_kb",swap_size,"num");put("swap_total_kb",mem["SwapTotal:"],"num")
    put("mmd_service",prop["init.svc.mmd"]);put("mmd_requested_size",prop["mmd.zram.size"]);put("mmd_requested_algorithm",prop["mmd.zram.comp_algorithm"]);put("mmd_setup_complete",prop["mmd.setup_complete"]);put("mmd_zram_enabled",prop["mmd.zram.enabled"])
    put("zram_platform_persistent_size",prop["persist.vendor.zram_swap_size_v2"]);put("zram_owner",prop["mmd.zram.enabled"]=="true" ? "mmd" : "unknown");put("zram_target_supported",supported ? "true" : "false","raw");put("zram_effective_state",swap_state)
    put("zram_orig_bytes",mm[1],"num");put("zram_compr_bytes",mm[2],"num");put("zram_mem_used_bytes",mm[3],"num");put("zram_failed_reads",io[1],"num");put("zram_failed_writes",io[2],"num");put("zram_invalid_io",io[3],"num");put("zram_bd_count_4k",bd[1],"num");put("zram_bd_reads_4k",bd[2],"num");put("zram_bd_writes_4k",bd[3],"num");put("zram_page_size",page,"num");put("mem_total_bytes",ram,"num")
    put("stock",original_ok ? params(".memory_original") : "null","raw")
    put("original_size",original_ok ? value(".memory_original","size") : "");put("original_algorithm",original_ok ? value(".memory_original","algorithm") : "");put("original_source",original_ok ? "original_vendor_namespace_and_kernel" : "unavailable")
    put("limits","{\"swappiness\":{\"min\":" limits[1] ",\"max\":" limits[2] ",\"step\":1},\"min_free_kbytes\":{\"min\":" limits[3] ",\"max\":" int(ram/1024/limits[12]) ",\"step\":1},\"watermark_scale_factor\":{\"min\":" limits[4] ",\"max\":" limits[5] ",\"step\":1},\"vfs_cache_pressure\":{\"min\":" limits[6] ",\"max\":" limits[7] ",\"step\":1}}","raw")
    put("zram_input_limits","{\"default_unit\":\"mb\",\"mb\":{\"min\":0.01,\"max\":" sprintf("%.2f",int(ram*limits[11]/100/10000)/100) ",\"step\":0.01},\"percent\":{\"min\":" limits[10] ",\"max\":" limits[11] ",\"step\":1}}","raw")
    list="[";gsub(/[\[\]]/,"",algorithms);algorithm_count=split(algorithms,parts," ");j=0;for(i=1;i<=algorithm_count;i++)if(parts[i] ~ /^[A-Za-z0-9_-]+$/ && !(parts[i]=="lz77eh" && page!=4096)){list=list (j++ ? "," : "") quote(parts[i])}put("zram_algorithms",list "]","raw")
    put("android_sdk",prop["ro.build.version.sdk"],"num");put("mmd_features_supported",supported ? "true" : "false","raw");put("mmd_writeback_enabled",prop["mmd.zram.writeback.enabled"]=="true" ? "true" : "false","raw");put("mmd_recompression_enabled",prop["mmd.zram.recompression.enabled"]=="true" ? "true" : "false","raw")
    auto=value(".memory_boot_config","auto_apply")=="on" ? "true" : "false";vm_enabled=value(".memory_boot_config","vm_enabled")=="on" ? "true" : "false"
    boot_pending=(value(".memory_boot_result","boot_id")!=boot || value(".memory_boot_config","auto_apply")!=value(".memory_boot_result","auto_apply"))
    if(auto=="true"){
        if(value(".memory_boot_config","size")!=value(".memory_boot_result","requested_size") || value(".memory_boot_config","algorithm")!=value(".memory_boot_result","requested_algorithm") || value(".memory_boot_config","vm_enabled")!=value(".memory_boot_result","vm_enabled"))boot_pending=1
        if(vm_enabled=="true" && params(".memory_boot_config")!=params(".memory_boot_result"))boot_pending=1
    }
    boot_phase=value(".memory_boot_result","boot_id")==boot ? value(".memory_boot_result","phase") : "pending"
    boot_json="{\"auto_apply\":" auto ",\"vm_enabled\":" vm_enabled ",\"size\":" quote(value(".memory_boot_config","size")) ",\"algorithm\":" quote(value(".memory_boot_config","algorithm")) ",\"phase\":" quote(boot_phase) ",\"pending_reboot\":" (boot_pending ? "true" : "false") ",\"vm\":" params(".memory_boot_config") "}";put("memory_boot",boot_json,"raw")
    put("zram_online_supported",online,"raw");put("zram_online_reason",reason);put("zram_mem_available_bytes",available,"num");put("zram_swapoff_required_bytes",required,"num")
    put("zram_operation","{\"id\":" quote(value(".zram_runtime_state","id")) ",\"phase\":" quote(phase) ",\"reason\":" quote(value(".zram_runtime_state","reason")) ",\"pending\":" pending ",\"size\":" quote(value(".zram_runtime_state","size")) ",\"algorithm\":" quote(value(".zram_runtime_state","algorithm")) "}","raw")
    preset=original_ok ? "{\"name\":\"模块预设\",\"size\":" quote(value(".memory_original","size")) ",\"algorithm\":" quote(value(".memory_original","algorithm")) ",\"swappiness\":" limits[8] ",\"min_free_kbytes\":" limits[9] ",\"watermark_scale_factor\":" number(value(".memory_original","watermark_scale_factor")) ",\"vfs_cache_pressure\":" number(value(".memory_original","vfs_cache_pressure")) "}" : "null"
    put("module_preset",preset,"raw")
    printf "}\n"
}
