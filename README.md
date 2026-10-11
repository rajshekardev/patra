# Patra 

here is how it looks. 

```
---
title: "Patra — Full-Stack Demo"
description: "A full-stack application built with Patra."
lang: "en"
canonical: "/"
robots: "index, follow"

rendering:
  ssr: true
  prerender: true
---

<odin server>
import "core:fmt"
import "patra:rpc"

greet :: proc(name: string) -> string {
    return fmt.aprintf("Hello, from %s!", name)
}

rpc.greet(greet)

</odin>

<odin client>
import "patra:rpc"
name := "Patra"
greeting := rpc.greet(name)

</odin>

<script lang="ts">
import rpc from "patra/rpc"

const demo = $state()

$effect({
    if greet.data
})

// client only
</script>

{# if greet.isLoading}
Loading...
{# else if greet.isError}

{# else }


<div class="flex flex-col text-xl"> 
this is a patra document
</div>

<style >
body {
    background: black;
    color: white;
}
</style>


```
