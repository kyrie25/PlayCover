#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

extern kern_return_t playcover_vm_protect(mach_port_name_t task,
                                          mach_vm_address_t address,
                                          mach_vm_size_t size,
                                          boolean_t set_max,
                                          vm_prot_t new_prot);

#if defined(__arm64__)
__asm__(
".global _playcover_vm_protect\n"
"_playcover_vm_protect:\n"
"    mov x16, #-0xe\n"
"    svc #0x80\n"
"    ret\n"
);
#else
kern_return_t playcover_vm_protect(mach_port_name_t task,
                                   mach_vm_address_t address,
                                   mach_vm_size_t size,
                                   boolean_t set_max,
                                   vm_prot_t new_prot) {
    return vm_protect(task, address, size, set_max, new_prot);
}
#endif

__attribute__((constructor))
static void PlayCoverCryptidPatchInit(void) {
    uint32_t count = _dyld_image_count();
    struct mach_header_64 *mh = NULL;
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (hdr && hdr->magic == MH_MAGIC_64 && hdr->filetype == MH_EXECUTE) {
            mh = (struct mach_header_64 *)hdr;
            break;
        }
    }
    if (!mh) { return; }

    struct encryption_info_command_64 *eic = NULL;
    uint8_t *cursor = (uint8_t *)(mh + 1);
    uint8_t *end = cursor + mh->sizeofcmds;
    for (uint32_t i = 0; i < mh->ncmds && end - cursor >= (ptrdiff_t)sizeof(struct load_command); i++) {
        struct load_command *lc = (struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || lc->cmdsize > (size_t)(end - cursor)) { return; }
        if (lc->cmd == LC_ENCRYPTION_INFO_64 && lc->cmdsize >= sizeof(struct encryption_info_command_64)) {
            eic = (struct encryption_info_command_64 *)cursor;
            break;
        }
        cursor += lc->cmdsize;
    }
    if (!eic || eic->cryptid != 0) { return; }

    kern_return_t kr = playcover_vm_protect(mach_task_self(), (mach_vm_address_t)mh, 0x1000, false,
                                            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[PlayCover][CryptidPatch] vm_protect failed: %#x", kr);
        return;
    }
    eic->cryptid = 1;
    playcover_vm_protect(mach_task_self(), (mach_vm_address_t)mh, 0x1000, false, VM_PROT_READ);
    NSLog(@"[PlayCover][CryptidPatch] patched LC_ENCRYPTION_INFO_64 cryptid 0 -> 1");
}
