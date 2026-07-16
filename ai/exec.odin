package ai

import "core:fmt"
import "core:log"
import "core:os"
import "core:sync"

// _exec_seq gives each exec_capture call a unique temp file suffix
// (calls happen concurrently from the bot, scheduler, and web threads).
_exec_seq: u64

// exec_capture runs a command, waits for it to exit, and returns its output.
// Replacement for os.process_exec, which busy-polls the child's pipes
// (zero-timeout poll in a tight loop) and pins a CPU core for the child's
// entire lifetime — fatal for long-running children like curl's 30s
// Telegram long poll. This variant redirects output to temp files and
// blocks in process_wait instead.
//
// stdout/stderr are allocated on context.temp_allocator, matching how the
// call sites previously used os.process_exec.
exec_capture :: proc(command: []string) -> (state: os.Process_State, stdout: string, stderr: string, ok: bool) {
	seq := sync.atomic_add(&_exec_seq, 1)
	out_path := fmt.tprintf("/tmp/todoapp_exec_{}_{}.out", os.get_pid(), seq)
	err_path := fmt.tprintf("/tmp/todoapp_exec_{}_{}.err", os.get_pid(), seq)

	out_f, oerr := os.open(out_path, {.Write, .Create, .Trunc})
	if oerr != nil {
		log.errorf("exec_capture: open {} failed: %v", out_path, oerr)
		return
	}
	err_f, eerr := os.open(err_path, {.Write, .Create, .Trunc})
	if eerr != nil {
		os.close(out_f)
		os.remove(out_path)
		log.errorf("exec_capture: open {} failed: %v", err_path, eerr)
		return
	}

	desc := os.Process_Desc{
		command = command,
		stdout  = out_f,
		stderr  = err_f,
	}
	process, perr := os.process_start(desc)

	// The child holds its own descriptors after start; drop ours.
	os.close(out_f)
	os.close(err_f)
	defer os.remove(out_path)
	defer os.remove(err_path)

	if perr != nil {
		log.errorf("exec_capture: start {} failed: %v", command[0], perr)
		return
	}

	wstate, werr := os.process_wait(process)
	if werr != nil {
		log.errorf("exec_capture: wait for {} failed: %v", command[0], werr)
		return
	}

	out_data, _ := os.read_entire_file_from_path(out_path, context.temp_allocator)
	err_data, _ := os.read_entire_file_from_path(err_path, context.temp_allocator)
	return wstate, string(out_data), string(err_data), true
}
