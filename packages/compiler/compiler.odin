package compiler




remove_bom :: proc(source: string) -> string {
    if len(source) > 0 && source[0] == 0xEF &&
       len(source) >= 3 &&
       source[1] == 0xBB &&
       source[2] == 0xBF {
        return source[3:]
    }

    return source
}
