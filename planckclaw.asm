; planckclaw.asm — The smallest possible functional AI agent on Linux x86-64
; Pure router: interact ↔ brain ↔ claw, via 3 FIFO pairs.
; Assembled with NASM, linked with ld.

bits 64
default rel

; ============================================================================
; SYSCALL NUMBERS
; ============================================================================
%define SYS_READ    0
%define SYS_WRITE   1
%define SYS_OPEN    2
%define SYS_CLOSE   3
%define SYS_LSEEK   8
%define SYS_ACCESS  21
%define SYS_EXIT    60

; open() flags
%define O_RDONLY    0
%define O_WRONLY    1
%define O_RDWR     2
%define O_CREAT    0x40
%define O_APPEND   0x400
%define O_TRUNC    0x200

; lseek whence
%define SEEK_SET   0
%define SEEK_END   2

; access() mode
%define F_OK       0

; ============================================================================
; BUFFER SIZES
; ============================================================================
%define MAX_MSG_IN      4096
%define MAX_JSON_OUT    65536
%define MAX_JSON_IN     65536
%define MAX_SOUL        8192
%define MAX_SUMMARY     8192
%define MAX_HISTORY     32768
%define MAX_LINE        4096
%define MAX_RESPONSE    8192

; ============================================================================
; DATA SECTION — constant strings
; ============================================================================
section .data

; FIFO paths
interact_in_path:   db "/tmp/planckclaw/interact_in", 0
interact_out_path:  db "/tmp/planckclaw/interact_out", 0
brain_in_path:      db "/tmp/planckclaw/brain_in", 0
brain_out_path:     db "/tmp/planckclaw/brain_out", 0
claw_in_path:       db "/tmp/planckclaw/claw_in", 0
claw_out_path:      db "/tmp/planckclaw/claw_out", 0

; Env var names
env_dir:            db "PLANCKCLAW_DIR", 0
env_hist_max:       db "HISTORY_MAX", 0
env_hist_keep:      db "HISTORY_KEEP", 0

; Default values
default_dir:        db "./memory", 0
default_soul:       db "You are a helpful personal assistant.", 0
default_soul_len:   equ $ - default_soul - 1

; File names (appended to dir)
soul_suffix:        db "/soul.md", 0
summary_suffix:     db "/summary.md", 0
history_suffix:     db "/history.jsonl", 0

; JSON payload fragments
json_start:         db '{"model":"claude-haiku-4-5-20251001","max_tokens":1024,"system":"', 0
json_sep_summary:   db '\n---\nCONVERSATION SUMMARY:\n', 0
json_msgs_start:    db '","messages":[', 0
json_role_user:     db '{"role":"user","content":"', 0
json_role_asst:     db '{"role":"assistant","content":"', 0
json_quote_close:   db '"}', 0
json_comma:         db ',', 0
json_end:           db ']}', 0
json_delim:         db 10, 10, 0  ; \n\n delimiter

; Compaction JSON fragments
compact_start:      db '{"model":"claude-haiku-4-5-20251001","max_tokens":2048,"system":"You are a memory compaction assistant. Summarize the following conversation, preserving: key facts about the user, their preferences, decisions made, ongoing projects, and important context. Be concise but complete. Output only the summary, no preamble.","messages":[{"role":"user","content":"EXISTING SUMMARY:\n', 0
compact_mid:        db '\n\nCONVERSATION TO SUMMARIZE:\n', 0
compact_end:        db '"}]}', 0

; History JSONL line templates
hist_user_pre:      db '{"role":"user","content":"', 0
hist_asst_pre:      db '{"role":"assistant","content":"', 0
hist_post:          db '"}', 10, 0  ; "}\n

; Error response
error_response:     db "I'm temporarily unavailable. Please try again shortly.", 0
error_response_len: equ $ - error_response - 1

; JSON key targets for parser
key_content:        db "content", 0
key_text:           db "text", 0
key_error:          db "error", 0

; Tool use JSON key targets
key_stop_reason:    db "stop_reason", 0
key_type:           db "type", 0
key_id:             db "id", 0
key_name:           db "name", 0
key_input:          db "input", 0
val_tool_use:       db "tool_use", 0

; Tool use follow-up message fragments
asst_content_pre:   db ',{"role":"assistant","content":', 0
asst_content_post:  db '}', 0
tool_result_pre:    db ',{"role":"user","content":[{"type":"tool_result","tool_use_id":"', 0
tool_result_mid:    db '","content":"', 0
tool_result_post:   db '"}]}', 0

; Tools bridge discovery command
tools_discovery_cmd: db "__list_tools__", 10, 0  ; __list_tools__\n
tools_discovery_len: equ $ - tools_discovery_cmd - 1

; Newline
newline:            db 10

; ============================================================================
; BSS SECTION — runtime buffers (zero binary cost)
; ============================================================================
section .bss

; File descriptors
fd_interact_in:  resq 1
fd_interact_out: resq 1
fd_brain_in:     resq 1
fd_brain_out:    resq 1
fd_claw_in:   resq 1
fd_claw_out:  resq 1

; Configuration
history_max:    resq 1      ; max lines before compaction
history_keep:   resq 1      ; lines to keep after compaction

; Buffers
msg_in_buf:     resb MAX_MSG_IN
json_out_buf:   resb MAX_JSON_OUT
json_in_buf:    resb MAX_JSON_IN
soul_buf:       resb MAX_SOUL
summary_buf:    resb MAX_SUMMARY
history_buf:    resb MAX_HISTORY
line_buf:       resb MAX_LINE
response_buf:   resb MAX_RESPONSE
channel_buf:    resb 64         ; channel_id from incoming message
path_buf:       resb 256        ; constructed file paths
temp_buf:       resb MAX_LINE   ; temporary scratch

; Lengths
soul_len:       resq 1
summary_len:    resq 1
msg_len:        resq 1
response_len:   resq 1

; Env pointer
envp_ptr:       resq 1

; Tool use state
json_msgs_end_pos:  resq 1      ; saved position in json_out_buf for tool follow-up
tool_content_start: resq 1      ; pointer to content array [ in LLM response
tool_content_end:   resq 1      ; pointer past content array ] in LLM response
tool_id_buf:        resb 128    ; extracted tool_use id
tool_name_buf:      resb 64     ; extracted tool name
tool_input_buf:     resb 512    ; extracted tool input JSON
tool_input_len:     resq 1      ; length of tool input
tool_result_buf:    resb 4096   ; tool result from bridge
tool_result_len:    resq 1      ; length of tool result

; Dynamic tools definition (from bridge)
tools_json_buf:     resb 4096   ; tools JSON array from discovery
tools_json_len:     resq 1      ; length of tools JSON

; ============================================================================
; TEXT SECTION — code
; ============================================================================
section .text
global _start

_start:
    ; Save envp: on entry, rsp points to argc
    ; Stack layout: [argc] [argv0] [argv1] ... [NULL] [envp0] [envp1] ... [NULL]
    mov rax, [rsp]          ; argc
    lea rdi, [rsp + 8]      ; argv
    lea rsi, [rdi + rax*8 + 8]  ; envp = argv + argc + 1 (null terminator)
    mov [envp_ptr], rsi

    ; --- Set defaults ---
    mov qword [history_max], 200
    mov qword [history_keep], 40

    ; --- Read environment variables ---
    ; Try HISTORY_MAX
    lea rdi, [env_hist_max]
    call getenv
    test rax, rax
    jz .skip_hmax
    call atoi
    mov [history_max], rax
.skip_hmax:

    ; Try HISTORY_KEEP
    lea rdi, [env_hist_keep]
    call getenv
    test rax, rax
    jz .skip_hkeep
    call atoi
    mov [history_keep], rax
.skip_hkeep:

    ; --- Build directory path ---
    lea rdi, [env_dir]
    call getenv
    test rax, rax
    jnz .have_dir
    lea rax, [default_dir]
.have_dir:
    mov rsi, rax            ; rsi = directory path

    ; --- Read soul.md ---
    lea rdi, [path_buf]
    call strcpy             ; copy dir to path_buf
    mov rsi, rax            ; rax = end of copied string
    lea rdi, [soul_suffix]
    xchg rdi, rsi           ; rdi = dest (end of path), rsi = suffix
    call strcat

    lea rdi, [path_buf]
    lea rsi, [soul_buf]
    mov rdx, MAX_SOUL
    call read_file
    cmp rax, 0
    jg .soul_ok
    ; Use default soul
    lea rsi, [default_soul]
    lea rdi, [soul_buf]
    mov rcx, default_soul_len
    rep movsb
    mov rax, default_soul_len
.soul_ok:
    mov [soul_len], rax

    ; --- Read summary.md ---
    ; Rebuild path: dir + /summary.md
    lea rdi, [env_dir]
    call getenv
    test rax, rax
    jnz .have_dir2
    lea rax, [default_dir]
.have_dir2:
    mov rsi, rax
    lea rdi, [path_buf]
    call strcpy
    mov rsi, rax
    lea rdi, [summary_suffix]
    xchg rdi, rsi
    call strcat

    lea rdi, [path_buf]
    lea rsi, [summary_buf]
    mov rdx, MAX_SUMMARY
    call read_file
    cmp rax, 0
    jg .summary_ok
    xor rax, rax
.summary_ok:
    mov [summary_len], rax

    ; --- Open FIFOs ---
    lea rdi, [interact_in_path]
    mov rsi, O_RDONLY
    call sys_open_file
    mov [fd_interact_in], rax

    lea rdi, [interact_out_path]
    mov rsi, O_WRONLY
    call sys_open_file
    mov [fd_interact_out], rax

    lea rdi, [brain_in_path]
    mov rsi, O_WRONLY
    call sys_open_file
    mov [fd_brain_in], rax

    lea rdi, [claw_in_path]
    mov rsi, O_WRONLY
    call sys_open_file
    mov [fd_claw_in], rax

    ; brain_out and claw_out are opened on-demand to avoid deadlock:
    ; opening them here (O_RDONLY) would block until the bridge opens the
    ; write end, but bridges only write after receiving a request.

; ============================================================================
; MAIN LOOP
; ============================================================================
main_loop:
    ; Step 1: read from interact_in (blocking)
    mov rdi, [fd_interact_in]
    lea rsi, [msg_in_buf]
    mov rdx, MAX_MSG_IN - 1
    call sys_read
    cmp rax, 0
    jle .reopen_interact_in ; EOF or error — reopen FIFO
    mov [msg_len], rax
    ; Null-terminate
    lea rdi, [msg_in_buf]
    add rdi, rax
    mov byte [rdi], 0

    ; Step 2: Parse channel_id and message (separated by \t, terminated by \n)
    lea rsi, [msg_in_buf]
    lea rdi, [channel_buf]
    ; Copy channel_id until \t
.parse_chan:
    lodsb
    cmp al, 9               ; \t
    je .chan_done
    cmp al, 0
    je main_loop            ; malformed, skip
    stosb
    jmp .parse_chan
.chan_done:
    mov byte [rdi], 0       ; null-terminate channel_id
    ; rsi now points to message content
    ; Find end of message (strip trailing \n)
    mov rdi, rsi
    call strlen
    mov rcx, rax            ; message length
    ; Strip trailing newline
    cmp rcx, 0
    je main_loop
    lea rdi, [rsi + rcx - 1]
    cmp byte [rdi], 10
    jne .no_strip
    mov byte [rdi], 0
    dec rcx
.no_strip:
    ; rsi = message start, rcx = message length
    ; Save message pointer
    push rsi
    push rcx

    ; Step 3: Discovery — ask tools bridge for available tools
    call discover_tools

    ; Step 4: Read last HISTORY_KEEP lines from history.jsonl
    call load_recent_history

    ; Step 5: Build JSON payload
    pop rcx                 ; message length
    pop rsi                 ; message pointer
    push rsi                ; save again for history append
    push rcx
    call build_json_payload

    ; Step 6: Write payload to brain_in with \n\n delimiter
    mov rdi, [fd_brain_in]
    lea rsi, [json_out_buf]
    mov rdx, rax            ; rax = payload length from build_json_payload
    call sys_write

    ; Write \n\n delimiter
    mov rdi, [fd_brain_in]
    lea rsi, [json_delim]
    mov rdx, 2
    call sys_write

    ; Step 7: Open brain_out (deferred to avoid deadlock), read response, close
    lea rdi, [brain_out_path]
    mov rsi, O_RDONLY
    call sys_open_file
    mov [fd_brain_out], rax

    call read_brain_response

    ; Close brain_out so bridge can reopen next round
    mov rdi, [fd_brain_out]
    mov rax, SYS_CLOSE
    syscall

    ; Step 8: Parse response — extract text, detect tool_use, or error
    lea rsi, [json_in_buf]
    call parse_llm_response
    ; rax = 0: error, 1: text response, 2: tool_use

    cmp rax, 2
    je .handle_tool_use

    test rax, rax
    jnz .have_response

    ; Error — use default error message
    lea rsi, [error_response]
    lea rdi, [response_buf]
    mov rcx, error_response_len
    rep movsb
    mov qword [response_len], error_response_len
    jmp .skip_history       ; don't save error exchanges

.handle_tool_use:
    ; Dispatch tool call to tools bridge via FIFO
    call dispatch_tool

    ; Build follow-up payload with assistant content + tool result
    call build_tool_followup_payload
    ; rax = payload length

    ; Send to brain bridge
    mov rdi, [fd_brain_in]
    lea rsi, [json_out_buf]
    mov rdx, rax
    call sys_write

    ; Write \n\n delimiter
    mov rdi, [fd_brain_in]
    lea rsi, [json_delim]
    mov rdx, 2
    call sys_write

    ; Open brain_out, read response, close
    lea rdi, [brain_out_path]
    mov rsi, O_RDONLY
    call sys_open_file
    mov [fd_brain_out], rax
    call read_brain_response
    mov rdi, [fd_brain_out]
    mov rax, SYS_CLOSE
    syscall

    ; Parse final response (expect text this time)
    lea rsi, [json_in_buf]
    call parse_llm_response
    cmp rax, 1
    je .have_response

    ; Error or unexpected second tool_use
    lea rsi, [error_response]
    lea rdi, [response_buf]
    mov rcx, error_response_len
    rep movsb
    mov qword [response_len], error_response_len
    jmp .skip_history

.have_response:
    ; Append to history.jsonl
    pop rcx                 ; message length
    pop rsi                 ; message pointer
    push rsi
    push rcx
    call append_history
    jmp .do_compact

.skip_history:
    ; Clean up stack from saved message pointer/length
    pop rcx
    pop rsi
    push rsi
    push rcx

.do_compact:
    ; Check compaction
    call count_history_lines
    cmp rax, [history_max]
    jl .no_compact
    call do_compaction
.no_compact:

    ; Write response to interact_out: channel_id\tresponse\n
    ; Build output in json_out_buf (reuse as scratch)
    lea rdi, [json_out_buf]
    lea rsi, [channel_buf]
    call strcpy_to          ; copy channel_id
    mov byte [rdi], 9       ; \t
    inc rdi
    lea rsi, [response_buf]
    mov rcx, [response_len]
    call escape_for_fifo
    mov byte [rdi], 10      ; \n
    inc rdi

    ; Calculate length and write
    lea rsi, [json_out_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rdi, [fd_interact_out]
    call sys_write

    ; Clean up stack
    pop rcx
    pop rsi

    jmp main_loop

.reopen_interact_in:
    ; Close and reopen interact_in (writer disconnected)
    mov rdi, [fd_interact_in]
    mov rax, SYS_CLOSE
    syscall
    lea rdi, [interact_in_path]
    mov rsi, O_RDONLY
    call sys_open_file
    mov [fd_interact_in], rax
    jmp main_loop

; ============================================================================
; SUBROUTINES
; ============================================================================

; --- sys_open_file: open file ---
; rdi = path, rsi = flags
; Returns fd in rax
sys_open_file:
    mov rax, SYS_OPEN
    mov rdx, 0o644          ; mode (for O_CREAT)
    syscall
    ret

; --- sys_read: read from fd ---
; rdi = fd, rsi = buf, rdx = count
; Returns bytes read in rax
sys_read:
    mov rax, SYS_READ
    syscall
    ret

; --- sys_write: write to fd ---
; rdi = fd, rsi = buf, rdx = count
; Returns bytes written in rax
sys_write:
    mov rax, SYS_WRITE
    syscall
    ret

; --- strlen: get length of null-terminated string ---
; rdi = string pointer
; Returns length in rax
strlen:
    push rdi
    xor rcx, rcx
    dec rcx                 ; rcx = -1 (max count)
    xor al, al              ; looking for null
    repne scasb
    not rcx
    dec rcx                 ; rcx = length
    mov rax, rcx
    pop rdi
    ret

; --- strcpy: copy null-terminated string ---
; rdi = dest, rsi = src
; Returns pointer past last char in rax
strcpy:
    push rdi
.sc_loop:
    lodsb
    stosb
    test al, al
    jnz .sc_loop
    lea rax, [rdi - 1]      ; point to the null terminator
    pop rdi
    ret

; --- escape_for_fifo: copy with escaping for FIFO protocol ---
; rsi = src, rdi = dest, rcx = src length
; Escapes: \ → \\, newline → \n, tab → \t
; Advances rdi past output
escape_for_fifo:
.eff_loop:
    test rcx, rcx
    jz .eff_done
    lodsb
    dec rcx
    cmp al, '\'
    je .eff_backslash
    cmp al, 10
    je .eff_newline
    cmp al, 9
    je .eff_tab
    stosb
    jmp .eff_loop
.eff_backslash:
    mov byte [rdi], '\'
    inc rdi
    mov byte [rdi], '\'
    inc rdi
    jmp .eff_loop
.eff_newline:
    mov byte [rdi], '\'
    inc rdi
    mov byte [rdi], 'n'
    inc rdi
    jmp .eff_loop
.eff_tab:
    mov byte [rdi], '\'
    inc rdi
    mov byte [rdi], 't'
    inc rdi
    jmp .eff_loop
.eff_done:
    ret

; --- strcpy_to: copy null-terminated string, advance rdi ---
; rdi = dest, rsi = src
; rdi is advanced past the copied string (not including null)
strcpy_to:
.sct_loop:
    lodsb
    test al, al
    jz .sct_done
    stosb
    jmp .sct_loop
.sct_done:
    ret

; --- strcat: append src to dest already in rdi ---
; rdi = dest (append point), rsi = src
; Returns pointer past last char in rax
strcat:
.sa_loop:
    lodsb
    stosb
    test al, al
    jnz .sa_loop
    lea rax, [rdi - 1]
    ret

; --- streq: compare two null-terminated strings ---
; rdi = str1, rsi = str2
; Returns 1 in rax if equal, 0 if not
streq:
.se_loop:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .se_neq
    test al, al
    jz .se_eq
    inc rdi
    inc rsi
    jmp .se_loop
.se_eq:
    mov rax, 1
    ret
.se_neq:
    xor rax, rax
    ret

; --- atoi: convert decimal string to integer ---
; rax = pointer to string
; Returns integer in rax
atoi:
    mov rsi, rax
    xor rax, rax
.atoi_loop:
    movzx rcx, byte [rsi]
    cmp cl, '0'
    jb .atoi_done
    cmp cl, '9'
    ja .atoi_done
    imul rax, 10
    sub cl, '0'
    add rax, rcx
    inc rsi
    jmp .atoi_loop
.atoi_done:
    ret

; --- getenv: find environment variable ---
; rdi = var name (null-terminated)
; Returns pointer to value in rax (or 0 if not found)
getenv:
    push rbx
    push r12
    mov r12, rdi            ; save var name
    mov rbx, [envp_ptr]
.ge_loop:
    mov rsi, [rbx]
    test rsi, rsi
    jz .ge_notfound
    ; Compare var name with envp entry up to '='
    mov rdi, r12
.ge_cmp:
    mov al, [rdi]
    test al, al
    jz .ge_check_eq         ; end of var name — check for '='
    mov cl, [rsi]
    cmp al, cl
    jne .ge_next
    inc rdi
    inc rsi
    jmp .ge_cmp
.ge_check_eq:
    cmp byte [rsi], '='
    jne .ge_next
    lea rax, [rsi + 1]      ; point past '='
    pop r12
    pop rbx
    ret
.ge_next:
    add rbx, 8
    jmp .ge_loop
.ge_notfound:
    xor rax, rax
    pop r12
    pop rbx
    ret

; --- read_file: read entire file into buffer ---
; rdi = path, rsi = buffer, rdx = max size
; Returns bytes read in rax (or -1 on error)
read_file:
    push r12
    push r13
    mov r12, rsi            ; buffer
    mov r13, rdx            ; max size
    ; Open file
    mov rsi, O_RDONLY
    call sys_open_file
    cmp rax, 0
    jl .rf_error
    mov rdi, rax            ; fd
    push rdi
    mov rsi, r12
    mov rdx, r13
    call sys_read
    mov r12, rax            ; save bytes read
    pop rdi                 ; fd
    push r12
    mov rax, SYS_CLOSE
    syscall
    pop rax                 ; return bytes read
    ; Null-terminate
    cmp rax, 0
    jle .rf_error
    push rax
    lea rdi, [r12]          ; buffer base was saved — no, r12 was clobbered
    pop rax
    pop r13
    pop r12
    ret
.rf_error:
    mov rax, -1
    pop r13
    pop r12
    ret

; --- build_history_path: construct path to history.jsonl ---
; Result in path_buf
build_history_path:
    push rsi
    lea rdi, [env_dir]
    call getenv
    test rax, rax
    jnz .bhp_have
    lea rax, [default_dir]
.bhp_have:
    mov rsi, rax
    lea rdi, [path_buf]
    call strcpy
    mov rdi, rax            ; end of dir path
    lea rsi, [history_suffix]
    call strcat
    pop rsi
    ret

; --- load_recent_history: read last HISTORY_KEEP lines from history.jsonl ---
; Stores result in history_buf, returns length in rax
load_recent_history:
    push rbx
    push r12
    push r13
    push r14

    call build_history_path

    ; Open history file
    lea rdi, [path_buf]
    mov rsi, O_RDONLY
    call sys_open_file
    cmp rax, 0
    jl .lrh_empty
    mov r12, rax            ; fd

    ; Read entire file into history_buf (we'll extract tail)
    mov rdi, r12
    lea rsi, [history_buf]
    mov rdx, MAX_HISTORY - 1
    call sys_read
    mov r13, rax            ; total bytes read

    ; Close file
    mov rdi, r12
    mov rax, SYS_CLOSE
    syscall

    cmp r13, 0
    jle .lrh_empty

    ; Null-terminate
    lea rdi, [history_buf]
    add rdi, r13
    mov byte [rdi], 0

    ; Count total lines and find start of last HISTORY_KEEP lines
    lea rsi, [history_buf]
    xor rcx, rcx            ; line count
    mov r14, rsi            ; start of "keep" region
.lrh_count:
    cmp rsi, rdi            ; rdi = end of data
    jge .lrh_counted
    cmp byte [rsi], 10      ; newline
    jne .lrh_nextc
    inc rcx
.lrh_nextc:
    inc rsi
    jmp .lrh_count
.lrh_counted:
    ; rcx = total line count
    ; We want to skip (rcx - HISTORY_KEEP) lines from the start
    mov rax, rcx
    sub rax, [history_keep]
    cmp rax, 0
    jle .lrh_use_all        ; fewer lines than HISTORY_KEEP, use all

    ; Skip 'rax' lines from start
    mov rcx, rax
    lea rsi, [history_buf]
.lrh_skip:
    cmp rcx, 0
    jle .lrh_found_start
    cmp byte [rsi], 10
    jne .lrh_skip_next
    dec rcx
.lrh_skip_next:
    inc rsi
    jmp .lrh_skip
.lrh_found_start:
    mov r14, rsi            ; r14 = start of lines to keep
    jmp .lrh_done

.lrh_use_all:
    lea r14, [history_buf]

.lrh_done:
    ; Move kept lines to beginning of history_buf if needed
    cmp r14, history_buf
    je .lrh_no_move
    lea rdi, [history_buf]
    mov rsi, r14
    ; Calculate length
    lea rax, [history_buf]
    add rax, r13
    sub rax, r14            ; bytes to copy
    mov rcx, rax
    push rax
    rep movsb
    mov byte [rdi], 0
    pop rax
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.lrh_no_move:
    mov rax, r13
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.lrh_empty:
    lea rdi, [history_buf]
    mov byte [rdi], 0
    xor rax, rax
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; --- json_escape_to: copy string to dest with JSON escaping ---
; rsi = source, rcx = source length, rdi = dest
; Returns: rdi advanced past written data
json_escape_to:
    test rcx, rcx
    jz .je_done
.je_loop:
    lodsb
    cmp al, '"'
    je .je_quote
    cmp al, 10             ; newline
    je .je_newline
    cmp al, 9              ; tab
    je .je_tab
    cmp al, '\'
    je .je_backslash
    cmp al, 13             ; carriage return
    je .je_cr
    stosb
    dec rcx
    jnz .je_loop
    jmp .je_done
.je_quote:
    mov byte [rdi], '\'
    mov byte [rdi+1], '"'
    add rdi, 2
    dec rcx
    jnz .je_loop
    jmp .je_done
.je_newline:
    mov byte [rdi], '\'
    mov byte [rdi+1], 'n'
    add rdi, 2
    dec rcx
    jnz .je_loop
    jmp .je_done
.je_tab:
    mov byte [rdi], '\'
    mov byte [rdi+1], 't'
    add rdi, 2
    dec rcx
    jnz .je_loop
    jmp .je_done
.je_backslash:
    mov byte [rdi], '\'
    mov byte [rdi+1], '\'
    add rdi, 2
    dec rcx
    jnz .je_loop
    jmp .je_done
.je_cr:
    mov byte [rdi], '\'
    mov byte [rdi+1], 'r'
    add rdi, 2
    dec rcx
    jnz .je_loop
.je_done:
    ret

; --- unescape_fifo_msg: unescape \\n → \n, \\t → \t, \\\\ → \\ in-place ---
; rsi = source string (null-terminated), rdi = dest
; Returns length in rax
unescape_fifo_msg:
    push rdi
    mov rdx, rdi            ; save start
.uf_loop:
    lodsb
    test al, al
    jz .uf_done
    cmp al, '\'
    jne .uf_store
    ; Check next char
    mov cl, [rsi]
    cmp cl, 'n'
    je .uf_newline
    cmp cl, 't'
    je .uf_tab
    cmp cl, '\'
    je .uf_bslash
    ; Not an escape sequence, store the backslash
    jmp .uf_store
.uf_newline:
    mov al, 10
    inc rsi
    jmp .uf_store
.uf_tab:
    mov al, 9
    inc rsi
    jmp .uf_store
.uf_bslash:
    mov al, '\'
    inc rsi
.uf_store:
    stosb
    jmp .uf_loop
.uf_done:
    mov byte [rdi], 0
    mov rax, rdi
    pop rdi
    sub rax, rdi
    ret

; --- build_json_payload: construct JSON for Claude API ---
; rsi = message text, rcx = message length
; Writes to json_out_buf, returns total length in rax
build_json_payload:
    push rbx
    push r12
    push r13

    mov r12, rsi            ; save message pointer
    mov r13, rcx            ; save message length

    lea rdi, [json_out_buf]

    ; {"model":"claude-haiku-4-5-20251001","max_tokens":1024,"system":"
    lea rsi, [json_start]
    call strcpy_to

    ; Inject soul.md content (JSON-escaped)
    lea rsi, [soul_buf]
    mov rcx, [soul_len]
    call json_escape_to

    ; If summary exists, add separator and summary
    cmp qword [summary_len], 0
    je .bjp_no_summary

    lea rsi, [json_sep_summary]
    call strcpy_to

    lea rsi, [summary_buf]
    mov rcx, [summary_len]
    call json_escape_to

.bjp_no_summary:
    ; ","messages":[
    lea rsi, [json_msgs_start]
    call strcpy_to

    ; Inject history lines as JSON array elements
    ; history_buf contains JSONL lines — each is already a JSON object
    lea rsi, [history_buf]
    cmp byte [rsi], 0
    je .bjp_no_history

    xor rbx, rbx            ; first entry flag
.bjp_hist_loop:
    cmp byte [rsi], 0
    je .bjp_hist_done
    cmp byte [rsi], 10       ; skip empty lines
    jne .bjp_hist_line
    inc rsi
    jmp .bjp_hist_loop
.bjp_hist_line:
    ; Add comma separator (except before first entry)
    test rbx, rbx
    jz .bjp_no_comma
    mov byte [rdi], ','
    inc rdi
.bjp_no_comma:
    inc rbx

    ; Copy the JSON line directly (it's already valid JSON)
.bjp_copy_line:
    lodsb
    cmp al, 10              ; newline = end of line
    je .bjp_hist_loop
    cmp al, 0
    je .bjp_hist_done_store
    stosb
    jmp .bjp_copy_line
.bjp_hist_done_store:
    jmp .bjp_hist_done

.bjp_hist_done:
    ; Add comma before current message
    cmp rbx, 0
    je .bjp_no_hist_comma
    mov byte [rdi], ','
    inc rdi
.bjp_no_hist_comma:
    jmp .bjp_add_current

.bjp_no_history:
.bjp_add_current:
    ; Add current message: {"role":"user","content":"..."}
    lea rsi, [json_role_user]
    call strcpy_to

    ; JSON-escape the incoming message
    ; First unescape FIFO escaping (\n, \t, \\), then re-escape for JSON
    ; Save rdi (json_out_buf write position) before clobbering it
    push rdi

    mov rsi, r12            ; original FIFO message
    lea rdi, [temp_buf]
    call unescape_fifo_msg
    mov r13, rax            ; unescaped length

    pop rdi                 ; restore json_out_buf write position

    ; JSON-escape from temp_buf into json_out_buf
    lea rsi, [temp_buf]
    mov rcx, r13
    call json_escape_to

    ; Close: "}
    lea rsi, [json_quote_close]
    call strcpy_to

    ; Save position for tool_use follow-up (end of messages content)
    mov [json_msgs_end_pos], rdi

    ; Close messages array: ]
    mov byte [rdi], ']'
    inc rdi

    ; Add tools definition from bridge: ,"tools":
    mov byte [rdi], ','
    inc rdi
    mov byte [rdi], '"'
    inc rdi
    mov byte [rdi], 't'
    inc rdi
    mov byte [rdi], 'o'
    inc rdi
    mov byte [rdi], 'o'
    inc rdi
    mov byte [rdi], 'l'
    inc rdi
    mov byte [rdi], 's'
    inc rdi
    mov byte [rdi], '"'
    inc rdi
    mov byte [rdi], ':'
    inc rdi

    ; Copy tools JSON array verbatim from tools_json_buf
    lea rsi, [tools_json_buf]
    mov rcx, [tools_json_len]
    rep movsb

    ; Close root object: }
    mov byte [rdi], '}'
    inc rdi
    mov byte [rdi], 0

    ; Calculate total length
    lea rax, [json_out_buf]
    mov rcx, rdi
    sub rcx, rax
    mov rax, rcx

    pop r13
    pop r12
    pop rbx
    ret

; --- strlen_from_rdi: get length of null-terminated string at rdi ---
; rdi = string, returns length in rax (does not modify rdi)
strlen_from_rdi:
    push rdi
    push rcx
    xor rcx, rcx
    dec rcx
    xor al, al
    repne scasb
    not rcx
    dec rcx
    mov rax, rcx
    pop rcx
    pop rdi
    ret

; --- read_brain_response: read from brain_out until \n\n ---
; Stores in json_in_buf, returns length in rax
read_brain_response:
    push rbx
    lea rbx, [json_in_buf]
    xor r8, r8              ; total bytes read
.rlr_loop:
    mov rdi, [fd_brain_out]
    lea rsi, [rbx + r8]
    mov rdx, MAX_JSON_IN - 1
    sub rdx, r8
    cmp rdx, 0
    jle .rlr_done           ; buffer full
    call sys_read
    cmp rax, 0
    jle .rlr_done
    add r8, rax

    ; Check for \n\n at end
    cmp r8, 2
    jl .rlr_loop
    lea rdi, [rbx + r8 - 2]
    cmp byte [rdi], 10
    jne .rlr_loop
    cmp byte [rdi + 1], 10
    jne .rlr_loop

    ; Found \n\n — strip it and null-terminate
    sub r8, 2
.rlr_done:
    lea rdi, [rbx + r8]
    mov byte [rdi], 0
    mov rax, r8
    pop rbx
    ret

; --- parse_llm_response: structural JSON parser ---
; rsi = JSON string (null-terminated) in json_in_buf
; Returns: 0 = error, 1 = text response (in response_buf), 2 = tool_use
; For tool_use: tool_id_buf, tool_name_buf, tool_content_start/end are set
parse_llm_response:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rsi            ; JSON start

    ; First check for "error" key at root level
    mov rsi, r12
    call json_find_root_key_error
    test rax, rax
    jnz .plr_error

    ; Check "stop_reason" key to detect tool_use
    mov rsi, r12
    lea rdi, [key_stop_reason]
    call json_find_key_at_depth0
    test rax, rax
    jz .plr_extract_text    ; no stop_reason, try text
    mov rsi, rax
    call skip_ws
    cmp byte [rsi], '"'
    jne .plr_extract_text
    inc rsi                 ; skip quote
    lea rdi, [val_tool_use]
    call json_key_matches
    test rax, rax
    jz .plr_extract_text    ; not "tool_use", extract text

    ; --- stop_reason is "tool_use" ---
    ; Find and save content array boundaries
    mov rsi, r12
    lea rdi, [key_content]
    call json_find_key_at_depth0
    test rax, rax
    jz .plr_error
    mov rsi, rax            ; points to [ of content array
    mov [tool_content_start], rsi

    ; Find end of content array
    push rsi
    call json_skip_value
    mov [tool_content_end], rsi
    pop rsi

    ; Navigate into content array to find tool_use block
    call skip_ws
    cmp byte [rsi], '['
    jne .plr_error
    inc rsi                 ; skip [

.plr_find_tool_block:
    call skip_ws
    cmp byte [rsi], ']'
    je .plr_error           ; end of array, no tool_use found
    cmp byte [rsi], '{'
    jne .plr_error

    mov r15, rsi            ; save position at { for skipping
    inc rsi                 ; skip {
    mov r14, rsi            ; save object interior start

    ; Check if "type" == "tool_use"
    mov rsi, r14
    lea rdi, [key_type]
    call json_find_key_in_object
    test rax, rax
    jz .plr_skip_content_obj
    mov rsi, rax
    call skip_ws
    cmp byte [rsi], '"'
    jne .plr_skip_content_obj
    inc rsi
    lea rdi, [val_tool_use]
    call json_key_matches
    test rax, rax
    jz .plr_skip_content_obj

    ; Found tool_use block! Extract "id"
    mov rsi, r14
    lea rdi, [key_id]
    call json_find_key_in_object
    test rax, rax
    jz .plr_error
    mov rsi, rax
    call skip_ws
    cmp byte [rsi], '"'
    jne .plr_error
    inc rsi
    lea rdi, [tool_id_buf]
    call json_extract_string

    ; Extract "name"
    mov rsi, r14
    lea rdi, [key_name]
    call json_find_key_in_object
    test rax, rax
    jz .plr_error
    mov rsi, rax
    call skip_ws
    cmp byte [rsi], '"'
    jne .plr_error
    inc rsi
    lea rdi, [tool_name_buf]
    call json_extract_string

    ; Extract "input" as raw JSON string into tool_input_buf
    mov rsi, r14
    lea rdi, [key_input]
    call json_find_key_in_object
    test rax, rax
    jz .plr_input_empty
    ; Copy raw JSON value (object) into tool_input_buf
    mov rsi, rax
    call skip_ws
    lea rdi, [tool_input_buf]
    ; Find end of this JSON value and copy verbatim
    push rsi                ; save start
    call json_skip_value
    mov rcx, rsi            ; end
    pop rsi                 ; start
    sub rcx, rsi            ; length
    push rcx
    rep movsb
    mov byte [rdi], 0
    pop rcx
    mov [tool_input_len], rcx
    jmp .plr_input_done
.plr_input_empty:
    lea rdi, [tool_input_buf]
    mov byte [rdi], '{'
    mov byte [rdi+1], '}'
    mov byte [rdi+2], 0
    mov qword [tool_input_len], 2
.plr_input_done:

    ; Return 2 = tool_use
    mov rax, 2
    jmp .plr_ret

.plr_skip_content_obj:
    ; Skip this content object and try next
    mov rsi, r15            ; restore to {
    call json_skip_value    ; skip entire object {...}
    call skip_ws
    cmp byte [rsi], ','
    jne .plr_find_tool_block
    inc rsi                 ; skip comma
    jmp .plr_find_tool_block

.plr_extract_text:
    ; Navigate to content[0].text (normal text response)
    mov rsi, r12
    lea rdi, [key_content]
    call json_find_key_at_depth0
    test rax, rax
    jz .plr_error
    mov rsi, rax

    call skip_ws
    cmp byte [rsi], '['
    jne .plr_error
    inc rsi

    call skip_ws
    cmp byte [rsi], '{'
    jne .plr_error
    inc rsi

    lea rdi, [key_text]
    call json_find_key_in_object
    test rax, rax
    jz .plr_error
    mov rsi, rax

    call skip_ws
    cmp byte [rsi], '"'
    jne .plr_error
    inc rsi

    lea rdi, [response_buf]
    call json_extract_string
    mov [response_len], rax

    mov rax, 1
    jmp .plr_ret

.plr_error:
    xor rax, rax
.plr_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; --- skip_ws: skip whitespace characters ---
; rsi = current position, advances rsi past whitespace
skip_ws:
    cmp byte [rsi], ' '
    je .sw_skip
    cmp byte [rsi], 9       ; tab
    je .sw_skip
    cmp byte [rsi], 10      ; newline
    je .sw_skip
    cmp byte [rsi], 13      ; CR
    je .sw_skip
    ret
.sw_skip:
    inc rsi
    jmp skip_ws

; --- json_find_root_key_error: check if root has "error" key ---
; rsi = JSON start
; Returns 1 if found, 0 if not
json_find_root_key_error:
    call skip_ws
    cmp byte [rsi], '{'
    jne .jfre_no
    inc rsi
.jfre_loop:
    call skip_ws
    cmp byte [rsi], '}'
    je .jfre_no
    cmp byte [rsi], '"'
    jne .jfre_no

    ; Read key
    inc rsi                 ; skip quote
    ; Check if this is "error"
    lea rdi, [key_error]
    call json_key_matches
    test rax, rax
    jnz .jfre_yes

    ; Skip this key's value and continue
    call json_skip_string_rest   ; skip rest of key string
    call skip_ws
    cmp byte [rsi], ':'
    jne .jfre_no
    inc rsi
    call skip_ws
    call json_skip_value
    call skip_ws
    cmp byte [rsi], ','
    jne .jfre_loop
    inc rsi
    jmp .jfre_loop

.jfre_yes:
    mov rax, 1
    ret
.jfre_no:
    xor rax, rax
    ret

; --- json_key_matches: check if current position matches a key ---
; rsi = position right after opening quote of key
; rdi = expected key (null-terminated)
; Returns 1 if match, 0 if not. rsi is NOT advanced.
json_key_matches:
    push rsi
    push rdi
.jkm_loop:
    mov al, [rdi]
    test al, al
    jz .jkm_check_end
    cmp al, [rsi]
    jne .jkm_no
    inc rsi
    inc rdi
    jmp .jkm_loop
.jkm_check_end:
    cmp byte [rsi], '"'     ; key should end with quote
    jne .jkm_no
    pop rdi
    pop rsi
    mov rax, 1
    ret
.jkm_no:
    pop rdi
    pop rsi
    xor rax, rax
    ret

; --- json_skip_string_rest: skip to end of JSON string ---
; rsi = inside a string (after opening quote or partway through)
; Advances rsi past the closing quote
json_skip_string_rest:
.jssr_loop:
    lodsb
    cmp al, '"'
    je .jssr_done
    cmp al, '\'
    jne .jssr_loop
    inc rsi                 ; skip escaped char
    jmp .jssr_loop
.jssr_done:
    ret

; --- json_skip_value: skip a JSON value ---
; rsi = start of value
; Advances rsi past the value
json_skip_value:
    call skip_ws
    cmp byte [rsi], '"'
    je .jsv_string
    cmp byte [rsi], '{'
    je .jsv_object
    cmp byte [rsi], '['
    je .jsv_array
    ; Number, bool, null — skip until delimiter
.jsv_primitive:
    lodsb
    cmp al, ','
    je .jsv_prim_done
    cmp al, '}'
    je .jsv_prim_done
    cmp al, ']'
    je .jsv_prim_done
    cmp al, 0
    je .jsv_prim_done
    jmp .jsv_primitive
.jsv_prim_done:
    dec rsi                 ; back up to delimiter
    ret

.jsv_string:
    inc rsi                 ; skip opening quote
    call json_skip_string_rest
    ret

.jsv_object:
    inc rsi                 ; skip {
    xor ecx, ecx            ; depth
.jsv_obj_loop:
    lodsb
    cmp al, '{'
    je .jsv_obj_deeper
    cmp al, '}'
    je .jsv_obj_shallower
    cmp al, '"'
    jne .jsv_obj_loop
    call json_skip_string_rest
    jmp .jsv_obj_loop
.jsv_obj_deeper:
    inc ecx
    jmp .jsv_obj_loop
.jsv_obj_shallower:
    test ecx, ecx
    jz .jsv_obj_done
    dec ecx
    jmp .jsv_obj_loop
.jsv_obj_done:
    ret

.jsv_array:
    inc rsi                 ; skip [
    xor ecx, ecx            ; depth
.jsv_arr_loop:
    lodsb
    cmp al, '['
    je .jsv_arr_deeper
    cmp al, ']'
    je .jsv_arr_shallower
    cmp al, '"'
    jne .jsv_arr_loop
    call json_skip_string_rest
    jmp .jsv_arr_loop
.jsv_arr_deeper:
    inc ecx
    jmp .jsv_arr_loop
.jsv_arr_shallower:
    test ecx, ecx
    jz .jsv_arr_done
    dec ecx
    jmp .jsv_arr_loop
.jsv_arr_done:
    ret

; --- json_find_key_at_depth0: find a key at root object level ---
; rsi = JSON string (should start with or point inside { at depth 0)
; rdi = key name (null-terminated)
; Returns pointer to value (after colon) in rax, or 0 if not found
json_find_key_at_depth0:
    push r12
    mov r12, rdi            ; save key name

    call skip_ws
    cmp byte [rsi], '{'
    jne .jfk_notfound
    inc rsi

.jfk_loop:
    call skip_ws
    cmp byte [rsi], '}'
    je .jfk_notfound
    cmp byte [rsi], '"'
    jne .jfk_notfound

    inc rsi                 ; skip opening quote
    mov rdi, r12
    call json_key_matches
    test rax, rax
    jnz .jfk_found

    ; Skip rest of this key
    call json_skip_string_rest
    call skip_ws
    cmp byte [rsi], ':'
    jne .jfk_notfound
    inc rsi
    call skip_ws
    call json_skip_value
    call skip_ws
    cmp byte [rsi], ','
    jne .jfk_loop
    inc rsi
    jmp .jfk_loop

.jfk_found:
    ; Advance past key closing quote
    mov rdi, r12
    call strlen
    add rsi, rax
    inc rsi                 ; skip closing quote
    call skip_ws
    cmp byte [rsi], ':'
    jne .jfk_notfound
    inc rsi                 ; skip colon
    call skip_ws
    mov rax, rsi
    pop r12
    ret

.jfk_notfound:
    xor rax, rax
    pop r12
    ret

; --- json_find_key_in_object: find key in current object ---
; rsi = inside object (after opening {), rdi = key name
; Returns pointer to value in rax, or 0
json_find_key_in_object:
    push r12
    mov r12, rdi

.jfko_loop:
    call skip_ws
    cmp byte [rsi], '}'
    je .jfko_notfound
    cmp byte [rsi], '"'
    jne .jfko_notfound

    inc rsi
    mov rdi, r12
    call json_key_matches
    test rax, rax
    jnz .jfko_found

    call json_skip_string_rest
    call skip_ws
    cmp byte [rsi], ':'
    jne .jfko_notfound
    inc rsi
    call skip_ws
    call json_skip_value
    call skip_ws
    cmp byte [rsi], ','
    jne .jfko_loop
    inc rsi
    jmp .jfko_loop

.jfko_found:
    mov rdi, r12
    call strlen
    add rsi, rax
    inc rsi                 ; skip closing quote
    call skip_ws
    cmp byte [rsi], ':'
    jne .jfko_notfound
    inc rsi
    call skip_ws
    mov rax, rsi
    pop r12
    ret

.jfko_notfound:
    xor rax, rax
    pop r12
    ret

; --- json_extract_string: extract JSON string value ---
; rsi = inside string (after opening quote)
; rdi = destination buffer
; Returns length in rax
json_extract_string:
    push rdi
    mov rdx, rdi            ; save start
.jes_loop:
    lodsb
    cmp al, '"'
    je .jes_done
    cmp al, 0
    je .jes_done
    cmp al, '\'
    jne .jes_store
    ; Handle escape
    lodsb
    cmp al, 'n'
    je .jes_newline
    cmp al, 't'
    je .jes_tab
    cmp al, 'r'
    je .jes_cr
    cmp al, '"'
    je .jes_store            ; literal quote
    cmp al, '\'
    je .jes_store            ; literal backslash
    cmp al, '/'
    je .jes_store            ; literal slash
    ; Unknown escape — store as-is
    jmp .jes_store
.jes_newline:
    mov al, 10
    jmp .jes_store
.jes_tab:
    mov al, 9
    jmp .jes_store
.jes_cr:
    mov al, 13
.jes_store:
    stosb
    jmp .jes_loop
.jes_done:
    mov byte [rdi], 0
    mov rax, rdi
    pop rdi
    sub rax, rdi
    ret

; --- strcmp: compare two null-terminated strings ---
; rsi = str1, rdi = str2
; Returns 0 if equal, 1 if not
strcmp:
    push rsi
    push rdi
.strcmp_loop:
    lodsb
    cmp al, [rdi]
    jne .strcmp_ne
    test al, al
    jz .strcmp_eq
    inc rdi
    jmp .strcmp_loop
.strcmp_eq:
    xor rax, rax
    pop rdi
    pop rsi
    ret
.strcmp_ne:
    mov rax, 1
    pop rdi
    pop rsi
    ret

; --- itoa_to: convert unsigned 64-bit integer to decimal ---
; rax = number, rdi = destination buffer
; Advances rdi past written digits
itoa_to:
    push rbx
    push rcx
    push rdx

    test rax, rax
    jnz .itoa_nonzero
    mov byte [rdi], '0'
    inc rdi
    pop rdx
    pop rcx
    pop rbx
    ret

.itoa_nonzero:
    xor rcx, rcx           ; digit count
    mov rbx, 10
.itoa_div:
    xor rdx, rdx
    div rbx
    add dl, '0'
    push rdx                ; push digit
    inc rcx
    test rax, rax
    jnz .itoa_div

.itoa_pop:
    pop rax
    stosb
    dec rcx
    jnz .itoa_pop

    pop rdx
    pop rcx
    pop rbx
    ret

; --- discover_tools: ask tools bridge for available tool definitions ---
; Writes __list_tools__\n to claw_in, reads JSON array from claw_out
; Stores in tools_json_buf, length in tools_json_len
discover_tools:
    push rbx

    ; Send discovery command
    mov rdi, [fd_claw_in]
    lea rsi, [tools_discovery_cmd]
    mov rdx, tools_discovery_len
    call sys_write

    ; Open claw_out, read response until \n\n, close
    lea rdi, [claw_out_path]
    mov rsi, O_RDONLY
    call sys_open_file
    mov [fd_claw_out], rax
    mov rbx, rax

    lea rdi, [tools_json_buf]
    xor r8, r8              ; total bytes
.dt_read:
    mov rdi, rbx
    lea rsi, [tools_json_buf + r8]
    mov rdx, 4096 - 1
    sub rdx, r8
    cmp rdx, 0
    jle .dt_done
    call sys_read
    cmp rax, 0
    jle .dt_done
    add r8, rax
    ; Check for \n\n delimiter
    cmp r8, 2
    jl .dt_read
    lea rdi, [tools_json_buf + r8 - 2]
    cmp byte [rdi], 10
    jne .dt_read
    cmp byte [rdi + 1], 10
    jne .dt_read
    sub r8, 2              ; strip delimiter
.dt_done:
    ; Null-terminate and save length
    lea rdi, [tools_json_buf + r8]
    mov byte [rdi], 0
    mov [tools_json_len], r8

    ; Close claw_out
    mov rdi, rbx
    mov rax, SYS_CLOSE
    syscall

    pop rbx
    ret

; --- dispatch_tool: send tool call to bridge, get result ---
; Reads tool_name_buf (+ tool input from LLM response)
; Sends {name}\t{input_json}\n to claw_in
; Reads result from claw_out into tool_result_buf
dispatch_tool:
    push rbx

    ; Build request in tool_result_buf (reuse as scratch): name\tinput\n
    lea rdi, [tool_result_buf]
    lea rsi, [tool_name_buf]
    call strcpy_to
    mov byte [rdi], 9       ; \t
    inc rdi
    lea rsi, [tool_input_buf]
    call strcpy_to
    mov byte [rdi], 10      ; \n
    inc rdi

    ; Calculate length and send
    lea rsi, [tool_result_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rdi, [fd_claw_in]
    call sys_write

    ; Open claw_out, read result until \n\n, close
    lea rdi, [claw_out_path]
    mov rsi, O_RDONLY
    call sys_open_file
    mov [fd_claw_out], rax
    mov rbx, rax

    xor r8, r8              ; total bytes
.dpt_read:
    mov rdi, rbx
    lea rsi, [tool_result_buf + r8]
    mov rdx, 4096 - 1
    sub rdx, r8
    cmp rdx, 0
    jle .dpt_done
    call sys_read
    cmp rax, 0
    jle .dpt_done
    add r8, rax
    ; Check for \n\n
    cmp r8, 2
    jl .dpt_read
    lea rdi, [tool_result_buf + r8 - 2]
    cmp byte [rdi], 10
    jne .dpt_read
    cmp byte [rdi + 1], 10
    jne .dpt_read
    sub r8, 2
.dpt_done:
    lea rdi, [tool_result_buf + r8]
    mov byte [rdi], 0
    mov [tool_result_len], r8

    ; Close claw_out
    mov rdi, rbx
    mov rax, SYS_CLOSE
    syscall

    pop rbx
    ret

; --- build_tool_followup_payload: append tool messages and rebuild ending ---
; Uses json_msgs_end_pos, tool_content_start/end, tool_id_buf, tool_result_buf
; Returns total payload length in rax
build_tool_followup_payload:
    ; Go back to saved position (end of messages content, before ])
    mov rdi, [json_msgs_end_pos]

    ; ,{"role":"assistant","content":<raw content array>}
    lea rsi, [asst_content_pre]
    call strcpy_to

    ; Copy raw content array from LLM response
    mov rsi, [tool_content_start]
    mov rcx, [tool_content_end]
    sub rcx, rsi
    rep movsb

    ; }
    lea rsi, [asst_content_post]
    call strcpy_to

    ; ,{"role":"user","content":[{"type":"tool_result","tool_use_id":"
    lea rsi, [tool_result_pre]
    call strcpy_to

    ; Tool ID (safe ASCII, no escaping needed)
    lea rsi, [tool_id_buf]
    call strcpy_to

    ; ","content":"
    lea rsi, [tool_result_mid]
    call strcpy_to

    ; Tool result (JSON-escaped)
    lea rsi, [tool_result_buf]
    mov rcx, [tool_result_len]
    call json_escape_to

    ; "}]}
    lea rsi, [tool_result_post]
    call strcpy_to

    ; Close messages array: ]
    mov byte [rdi], ']'
    inc rdi

    ; Tools definition from bridge: ,"tools":
    mov byte [rdi], ','
    inc rdi
    mov byte [rdi], '"'
    inc rdi
    mov byte [rdi], 't'
    inc rdi
    mov byte [rdi], 'o'
    inc rdi
    mov byte [rdi], 'o'
    inc rdi
    mov byte [rdi], 'l'
    inc rdi
    mov byte [rdi], 's'
    inc rdi
    mov byte [rdi], '"'
    inc rdi
    mov byte [rdi], ':'
    inc rdi

    ; Copy tools JSON array verbatim
    lea rsi, [tools_json_buf]
    mov rcx, [tools_json_len]
    rep movsb

    ; Close root object
    mov byte [rdi], '}'
    inc rdi
    mov byte [rdi], 0

    ; Calculate length
    lea rax, [json_out_buf]
    mov rcx, rdi
    sub rcx, rax
    mov rax, rcx
    ret

; --- append_history: append user+assistant exchange to history.jsonl ---
; rsi = user message (unescaped), rcx = message length
append_history:
    push rbx
    push r12
    push r13

    ; First unescape the FIFO message
    push rsi
    push rcx
    lea rdi, [temp_buf]
    call unescape_fifo_msg
    mov r12, rax            ; unescaped msg length
    pop rcx
    pop rsi

    call build_history_path

    ; Open history file for appending
    lea rdi, [path_buf]
    mov rsi, O_WRONLY | O_CREAT | O_APPEND
    call sys_open_file
    cmp rax, 0
    jl .ah_done
    mov rbx, rax            ; fd

    ; Build user line: {"role":"user","content":"..."}
    lea rdi, [line_buf]
    lea rsi, [hist_user_pre]
    call strcpy_to

    lea rsi, [temp_buf]
    mov rcx, r12
    call json_escape_to

    lea rsi, [hist_post]
    call strcpy_to

    ; Write user line
    lea rsi, [line_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rdi, rbx
    call sys_write

    ; Build assistant line: {"role":"assistant","content":"..."}
    lea rdi, [line_buf]
    lea rsi, [hist_asst_pre]
    call strcpy_to

    ; Escape response for JSON
    lea rsi, [response_buf]
    mov rcx, [response_len]
    call json_escape_to

    lea rsi, [hist_post]
    call strcpy_to

    ; Write assistant line
    lea rsi, [line_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rdi, rbx
    call sys_write

    ; Close
    mov rdi, rbx
    mov rax, SYS_CLOSE
    syscall

.ah_done:
    pop r13
    pop r12
    pop rbx
    ret

; --- count_history_lines: count lines in history.jsonl ---
; Returns count in rax
count_history_lines:
    push rbx

    call build_history_path

    lea rdi, [path_buf]
    lea rsi, [history_buf]
    mov rdx, MAX_HISTORY - 1
    call read_file
    cmp rax, 0
    jle .chl_zero

    mov rcx, rax
    lea rsi, [history_buf]
    xor rax, rax            ; line count
.chl_loop:
    cmp rcx, 0
    jle .chl_done
    cmp byte [rsi], 10
    jne .chl_next
    inc rax
.chl_next:
    inc rsi
    dec rcx
    jmp .chl_loop
.chl_done:
    pop rbx
    ret
.chl_zero:
    xor rax, rax
    pop rbx
    ret

; --- do_compaction: summarize old history and truncate ---
do_compaction:
    push rbx
    push r12
    push r13
    push r14

    call build_history_path

    ; Read full history
    lea rdi, [path_buf]
    lea rsi, [history_buf]
    mov rdx, MAX_HISTORY - 1
    call read_file
    cmp rax, 0
    jle .dc_done
    mov r13, rax            ; total bytes
    lea rdi, [history_buf + r13]
    mov byte [rdi], 0

    ; Count lines
    lea rsi, [history_buf]
    xor rcx, rcx
.dc_count:
    cmp byte [rsi], 0
    je .dc_counted
    cmp byte [rsi], 10
    jne .dc_cnt_next
    inc rcx
.dc_cnt_next:
    inc rsi
    jmp .dc_count
.dc_counted:
    mov r14, rcx            ; total lines

    ; Lines to compact = total - HISTORY_KEEP
    mov rax, r14
    sub rax, [history_keep]
    cmp rax, 0
    jle .dc_done

    ; Find the split point: skip (total - HISTORY_KEEP) lines
    mov rcx, rax
    lea rsi, [history_buf]
.dc_find_split:
    cmp rcx, 0
    jle .dc_split_found
    cmp byte [rsi], 10
    jne .dc_split_next
    dec rcx
.dc_split_next:
    inc rsi
    jmp .dc_find_split
.dc_split_found:
    mov r12, rsi            ; r12 = start of lines to keep

    ; Build compaction prompt in json_out_buf
    lea rdi, [json_out_buf]

    ; Start of compaction JSON
    lea rsi, [compact_start]
    call strcpy_to

    ; Add summary.md content (JSON-escaped)
    lea rsi, [summary_buf]
    mov rcx, [summary_len]
    call json_escape_to

    ; Middle separator
    lea rsi, [compact_mid]
    call strcpy_to

    ; Add old history lines (JSON-escaped)
    ; Old lines = history_buf[0..r12)
    lea rsi, [history_buf]
    mov rcx, r12
    lea rax, [history_buf]
    sub rcx, rax
    call json_escape_to

    ; End
    lea rsi, [compact_end]
    call strcpy_to

    ; Calculate length
    mov rax, rdi
    lea rcx, [json_out_buf]
    sub rax, rcx
    push rax                ; payload length
    push r12                ; save split point

    ; Send compaction request to LLM
    mov rdi, [fd_brain_in]
    lea rsi, [json_out_buf]
    pop r12                 ; restore split point
    pop rdx                 ; payload length
    push r12
    call sys_write

    ; Write \n\n delimiter
    mov rdi, [fd_brain_in]
    lea rsi, [json_delim]
    mov rdx, 2
    call sys_write

    ; Open fifo_llm_res for compaction response
    lea rdi, [brain_out_path]
    mov rsi, O_RDONLY
    call sys_open_file
    mov [fd_brain_out], rax

    ; Read compaction response
    call read_brain_response

    ; Close fifo_llm_res
    mov rdi, [fd_brain_out]
    mov rax, SYS_CLOSE
    syscall

    ; Parse response to get summary text
    lea rsi, [json_in_buf]
    call parse_llm_response
    test rax, rax
    jz .dc_skip_write

    ; Write summary to summary.md
    push r12
    lea rdi, [env_dir]
    call getenv
    test rax, rax
    jnz .dc_have_dir
    lea rax, [default_dir]
.dc_have_dir:
    mov rsi, rax
    lea rdi, [path_buf]
    call strcpy
    mov rdi, rax
    lea rsi, [summary_suffix]
    call strcat

    lea rdi, [path_buf]
    mov rsi, O_WRONLY | O_CREAT | O_TRUNC
    call sys_open_file
    cmp rax, 0
    jl .dc_skip_trunc
    mov rbx, rax

    lea rsi, [response_buf]
    mov rdx, [response_len]
    mov rdi, rbx
    call sys_write

    mov rdi, rbx
    mov rax, SYS_CLOSE
    syscall

    ; Update in-memory summary
    lea rdi, [summary_buf]
    lea rsi, [response_buf]
    mov rcx, [response_len]
    rep movsb
    mov byte [rdi], 0
    mov rax, [response_len]
    mov [summary_len], rax

.dc_skip_trunc:
    pop r12

    ; Rewrite history.jsonl with only kept lines
    call build_history_path

    lea rdi, [path_buf]
    mov rsi, O_WRONLY | O_CREAT | O_TRUNC
    call sys_open_file
    cmp rax, 0
    jl .dc_done
    mov rbx, rax

    ; Write kept lines (from r12 to end of history_buf)
    mov rsi, r12
    ; Calculate length to end
    lea rdi, [history_buf]
    add rdi, r13            ; end of data
    mov rdx, rdi
    sub rdx, rsi            ; length of kept data
    cmp rdx, 0
    jle .dc_close
    mov rdi, rbx
    call sys_write

.dc_close:
    mov rdi, rbx
    mov rax, SYS_CLOSE
    syscall
    jmp .dc_done

.dc_skip_write:
    pop r12

.dc_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
