# Cubyz
Cubyz is a 3D voxel sandbox game (inspired by Minecraft).

Cubyz has a bunch of interesting/unique features such as:
- Level of Detail (→ This enables far view distances.)
- 3D Chunks (→ There is no height or depth limit.)
- Procedural Crafting (→ There are infinite possibilites for tool crafting.)

# About
Cubyz is written in <img src="https://github.com/PixelGuys/Cubyz/assets/43880493/04dc89ca-3ef2-4167-9e1a-e23f25feb67c" width="20" height="20">
[Zig](https://ziglang.org/), a rather small language with some cool features and a focus on readability.

Windows and Linux are supported. Mac is not supported, as it does not have OpenGL 4.3.

Check out the [Discord server](https://discord.gg/XtqCRRG) for more information and announcements.

There are also some devlogs on [YouTube](https://www.youtube.com/playlist?list=PLYi_o2N3ImLb3SIUpTS_AFPWe0MUTk2Lf).

### History
Until recently (the Zig rewrite was started in August 2022) Cubyz was written in Java. You can still see the code in the [Cubyz-Java](https://github.com/PixelGuys/Cubyz-Java) repository and play it using the [Java Launcher](https://github.com/PixelGuys/Cubyz-Launcher/releases). `// TODO: Move this over to a separate repository`

Originally Cubyz was created on August 22, 2018 by <img src="https://avatars.githubusercontent.com/u/39484230" width="20" height="20">[zenith391](https://github.com/zenith391) and <img src="https://avatars.githubusercontent.com/u/39484479" width="20" height="20">[ZaUserA](https://github.com/ZaUserA). Back then, it was called "Cubz".

However, both of them lost interest at some point, and now Cubyz is maintained by <img src="https://avatars.githubusercontent.com/u/43880493" width="20" height="20">[IntegratedQuantum](https://github.com/IntegratedQuantum).

# My Additions
 GPU Rendered Realstic Clouds, made with Claude Opus 5, Max Effort, 1 Million Context, testing comands:
 - "/clouds": lists all new clouds
 - "/cloud clear": removes all clouds from sky
 - "/cloud set cloud_name": spawns clouds in sky
   
The folllowing Documentations were feed to AI to develop this feature:
- https://github.com/stegu/psrdnoise/
- https://github.com/stegu/webgl-noise
- https://gist.github.com/davidar/5f9677a0ccfbd63d7a8657ad9af3a856
- https://jcgt.org/published/0002/02/09/paper.pdf
- https://casual-effects.blogspot.com/2015/03/implemented-weighted-blended-order.html

 More content in the future. Most new content is vibe-coded, this is just a fun side project to play with friends and test AI capabilities.
